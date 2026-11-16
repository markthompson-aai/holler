# Simple actions run after a countdown, not a confirm card

Holler was built on the rule that every action waits on a confirm card. Working across many agents, waiting for each card and pressing Return added up, so we relaxed the rule: once you switch it on from the menu, a message to an idle or done agent and a start in a new tab of an existing workspace run after a 3-second countdown that you can cancel. Everything else keeps the card: closing a tab, interrupting an agent, a worktree start, and a message to an agent that is working. These either throw work away, leave things on disk, or land mid-task.

The countdown, not running at once, is there because speech gets misheard: a wrong agent name would send your message somewhere you didn't mean, and a delivered message can't be taken back. Holding the key to speak pauses it, so "actually, say this instead" can still replace the action before it runs.

## Considered options

- **Run at once, with no countdown.** Fastest, but a misheard target can't be caught.
- **A phrase per request ("just send it").** Rejected as the main switch: you'd have to remember to say it every time. Instead it works the other way round: a standing setting, and a request like "show me first" brings back the card for that one request.
- **A setting per kind of action.** One setting covers sends and starts; nobody asked to separate them.

## Consequences

- At the end of the countdown Holler checks the action again, as it does on confirm. If it no longer qualifies (say the agent has started working), it becomes a confirm card that says why, rather than running.
- Several actions from one request share one countdown, with a Cancel for each.
- A message or a first task that starts with `!` or `/` keeps its card too, with a warning on it (added 15 November 2026). Claude Code and Codex run such text as a shell command or a slash command rather than read it, so it isn't a simple action whoever it's for.
- The CLI still asks `[y/N]` for every action, since it's for testing.
- The Herdr-wide safety rules are unchanged: the workspace and folder filter, a blocked agent refused a message, only tabs Holler started can be closed, and targets re-checked against a fresh snapshot.
