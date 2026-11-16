# Reading Herdr over its socket instead of spawning `herdr`

Research note, 29 October 2026, against Herdr 0.9.3 (protocol 22) running on
the author's Mac. Read-only throughout: nothing was sent to a pane, started, closed,
focused or interrupted. The probe scripts and raw transcripts are not in the
repo; they are summarised here.

## The question

Every Holler request spawns the `herdr` binary several times: `herdr api
snapshot` to list agents, `herdr agent read <pane> --source recent-unwrapped`
(falling back to `--source visible`) once per agent in focus, another snapshot
for each action's pane re-resolve, and a snapshot for the key-term refresh after
each answer. Holler already speaks Herdr's socket for `events.subscribe`
(`HerdrEvents.swift`). Could the same socket serve snapshots and reads, and
would it be worth it?

## What the socket offers

`herdr api schema --json` prints the bundled API schema (272 KB, 102 request
methods), and `herdr status` prints the socket path:
`~/.config/herdr/herdr.sock`, or `HERDR_SOCKET_PATH` inside a Herdr pane,
exactly what `HerdrSocket.locate` already uses. There is no man page; the
binary points at https://herdr.dev/llms.txt and https://herdr.dev/agent-guide.md.

The protocol is newline-delimited JSON, one object per line, not JSON-RPC:
`{"id": "...", "method": "...", "params": {...}}` in, and either
`{"id", "result": {"type": "...", ...}}` or `{"id", "error": {"code", "message"}}`
back. `params` is required even when empty. The server answers one request per
connection and then closes it, so there is no pipelining and no connection to
keep alive; a second request on the same connection gets EOF. This matches the
one-subscription-per-connection behaviour already noted for events.

The read-only methods Holler would use, all confirmed working:

- `session.snapshot` with `{}`. Its reply is byte-for-byte what `herdr api
  snapshot` prints (the CLI just forwards it), so `HerdrSnapshot.decode` would
  need no change. 18 KB with 14 panes and 10 agents here.
- `agent.read` with `{"target": "<pane or agent name>", "source", "lines",
  "format"}` and `pane.read` with `{"pane_id", ...}`. Sources are spelt with
  underscores on the socket (`recent_unwrapped`; `recent-unwrapped` is an
  `invalid_request`), and the text comes back inside the JSON as
  `result.read.text`, with `truncated` and a `revision` counter, rather than as
  the plain text the CLI prints with `--format text`. `lines` omitted means the
  whole source; `lines: 0` means nothing.
- `agent.list`, `pane.list`, `workspace.list`, `tab.list`, `agent.get`,
  `pane.get`, `ping`. `ping` returns the version, protocol and capabilities.
- Errors are structured: `pane_not_found`, `agent_not_found`,
  `invalid_request`, instead of a line on stderr to match against.

Two side findings. The CLI itself opens two connections per command: a `ping`
(id `api-client:status`) to check compatibility, then the real request. And
`events.wait` on `pane_output_changed` is in the schema but answers
`unsupported_event_wait_match: events.wait currently supports pane agent status
matches`, so the socket still offers no output events in this version; `pane.output_matched` subscriptions were not tried.

The guessed names `snapshot`, `api.snapshot`, `read` and `panes.list` all
return `invalid_request` with the full list of valid methods, which is a
cheap way to discover the API without the schema.

## Timings

Wall clock from a Python client, pane `wJ:p1` (a working Claude agent), CLI and
socket calls interleaved so a busy moment in Herdr hits both alike. Median of
20 runs; the `turn` rows are a snapshot followed by three sequential reads.

| Call                                            | min    | median  | max    |
|-------------------------------------------------|-------:|--------:|-------:|
| CLI `herdr api snapshot`                        | 6.7 ms | 10.7 ms | 152 ms |
| socket `session.snapshot`                       | 1.1 ms | 104 ms* | 107 ms |
| CLI `herdr agent read --source visible`         | 6.8 ms | 9.4 ms  | 17 ms  |
| socket `agent.read` visible                     | 0.7 ms | 105 ms* | 106 ms |
| CLI `herdr pane read --source visible`          | 6.2 ms | 9.6 ms  | 114 ms |
| socket `pane.read` visible                      | 0.7 ms | 103 ms* | 106 ms |
| socket `agent.list`                             | 0.3 ms | 0.8 ms  | 2.3 ms |
| socket `ping` (connect and round trip floor)    | 0.0 ms | 0.1 ms  | 0.3 ms |
| CLI turn: snapshot + 3 reads                    | 23 ms  | 37 ms   | 61 ms  |
| socket turn: snapshot + 3 reads                 | 2.2 ms | 107 ms* | 210 ms |

\* The socket has two speeds. Left to itself it answers in 0.1 to 1 ms: 70
calls in a Python-only run, and 100 more in a run that sampled once a second,
never exceeded 2.3 ms, including pings made right after a CLI spawn. But in
three of seven runs, every socket request that came straight after a `herdr`
CLI call waited a steady 101 to 108 ms, and later requests in the same burst
were fast again; the CLI's own two connections showed the same ~105 ms each
when relayed through a logging proxy, yet the CLI run directly never took more
than 20 ms. The wait is Herdr's, not the client's (half-closing the write side,
splitting the newline into a second write, or pausing 150 ms made no
difference), and it looks like a 100 ms tick in the server, perhaps its render
loop when the TUI is redrawing. The trigger was not pinned down.

So a spawn costs about 8 ms over the socket call it wraps, and a full turn's
Herdr traffic is 25 to 60 ms today against 2 to 110 ms over the socket. Herdr
does the same work either way: reads past the visible height, which take 250 ms or more,
are server time and the transport does not change them.

## Recommendation

Stay with process spawns for now. The socket works and is simpler in some
ways (one connection per request, identical snapshot JSON, structured errors,
no child processes), but the saving is roughly 8 ms per call, a few tens of
milliseconds per turn, against turns that take seconds in the model; and on
the slow path it can be slower than the CLI. The CLI also hides things a
socket client would have to take on: the compatibility ping, waiting for an
agent to be ready in `agent start --timeout`, and whatever `agent prompt` does
beyond `agent.prompt`. The writes should stay on the CLI whatever happens.

Revisit if Holler starts polling Herdr (a live status view, or key-term or
watcher refreshes every few seconds across ten panes), where spawning a
process per pane per tick would be the wrong shape, or if the turn-timing log
shows Herdr calls as a visible share of a turn.

## The smallest first step, if switching

Add `request(method:params:) async throws -> Data` to `HerdrSocket`, reusing
its `SocketConnection` and framing: connect, write one line, read to the first
newline, close; raise `HerdrError.commandFailed` from an `error` reply. Put a
`HerdrTransport` seam behind `HerdrClient.snapshot()` with a CLI and a socket
implementation, and point only `session.snapshot` at the socket first, since
its JSON is identical to the CLI's and `HerdrSnapshot.decode` needs no change.
Fall back to the CLI when the socket is missing. Let the turn-timing log run for
a week before moving reads, which need the text taken from `result.read.text`
and `recent_unwrapped` spelt with an underscore.
