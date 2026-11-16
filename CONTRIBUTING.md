# Contributing to Holler

Thanks for helping. Bug reports, ideas and pull requests are all welcome. For anything bigger than a small fix, open an issue first so we can agree on the approach before you spend time on it.

## Building and testing

You need macOS 26 and Swift 6.2 (Xcode 26, or just the Command Line Tools).

```sh
swift build                 # every target
scripts/test.sh             # the test suite
scripts/build-app.sh        # build/Holler.app, the menu-bar app
```

`scripts/test.sh` wraps `swift test` so it also works with only the Command Line Tools installed, where SwiftPM can't find Swift Testing on its own. CI runs the same suite on each push to `main` and on pull requests, plus a release-mode run of the read tool's tests, since an optimised build once behaved differently from the debug one. It then runs `scripts/build-app.sh` and has the app draw every note state, so a break in the script or in the release build shows up there.

For your own settings while developing, copy `.env.example` to `.env` at the root of the clone. `scripts/build-app.sh` records that path in the app, and Holler prefers a key in it over the one in the Keychain.

## How the code is laid out

| Target | What's in it |
|---|---|
| `HollerCore` | Herdr access, the LLM Gateway tool loop, the assistant's tools and actions, settings. No Blurt dependency, so it builds and tests fast. Almost every test is here. |
| `HollerSpeech` | Speech in and out through [Blurt](https://github.com/AssemblyAI/blurt)'s engine: mic capture, the Dictation API client, the text-to-speech player. |
| `HollerApp` | The menu-bar app: the hotkey, the note, the key window, menus and sounds. `scripts/build-app.sh` wraps it in `Holler.app`. |
| `holler` | The command-line tool. |

Blurt is pinned to a commit in `Package.swift`: it moves fast, and an upgrade should be a deliberate diff.

`CLAUDE.md` and `docs/agents/` aren't about Holler itself: they configure AI coding agents working on this repo, telling them where issues live, which labels to use and which docs to read first.

[GLOSSARY.md](GLOSSARY.md) defines the words the code and docs use (note, pill, card, countdown, alert…), and [docs/adr](docs/adr) records the decisions that shape how Holler behaves. Please use the glossary's terms in code and issues, and read the ADRs before changing what they cover.

## Keeping permissions across rebuilds

macOS ties the Microphone and Input Monitoring permissions to the app's signature. `scripts/build-app.sh` signs ad hoc by default, which gives every build a new identity, so you grant both permissions again after each rebuild. A self-signed **Holler Dev** certificate in your login keychain fixes that: the script uses it when it's there. `SIGN_IDENTITY` overrides the choice (`SIGN_IDENTITY=-` forces ad hoc).

To create Holler Dev once per Mac (no Xcode or Apple account needed):

```sh
cd "$(mktemp -d)"
printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Holler Dev\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > cnf
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config cnf -keyout key.pem -out cert.pem
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out dev.p12 -passout pass:holler
security import dev.p12 -k ~/Library/Keychains/login.keychain-db -P holler -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "Holler Dev" ~/Library/Keychains/login.keychain-db  # asks for your login password
rm key.pem dev.p12; cd -
security find-identity -p codesigning                  # lists "Holler Dev" (CSSMERR_TP_NOT_TRUSTED is expected)
```

Because the certificate is self-signed, `security find-identity -v` hides it. Run the steps only once: a second Holler Dev certificate makes the build warn. The `set-key-partition-list` line lets codesign use the key without asking. Without it, every build stops at "codesign wants to access key…", and **Always Allow** doesn't make that stick. If you see the prompt, run that line again.

The same applies to the API key: with an ad hoc build, macOS asks whether the new build may read the key in the Keychain. A key in `.env` avoids the Keychain entirely.

## Checking the app without permissions

```sh
APP="build/Holler.app/Contents/MacOS/Holler"
"$APP" --check                                         # API key, hotkey, hidden folders, Herdr reachable
"$APP" --render-previews previews/                     # every pill and note state, light and dark, as PNGs
"$APP" --render-key-window previews/                   # the API key window, light and dark
"$APP" --snapshot "what are my agents up to?" out.png  # a live answer through the real panel
"$APP" --show-note summary dark                        # one sample state in the real panel, over a dark backdrop
```

## Golden images

`Tests/Goldens/note/` holds a PNG of every preview state of the note, and `scripts/check-previews.sh` builds the app, renders them afresh and fails on any change, so a layout regression shows up before it's merged. Please run it before opening a pull request that touches the note.

The mark is drawn at one fixed moment in these renders, so they come out the same every time on one Mac. A failed check leaves the fresh renders and a `<state>-diff.png` per change (red where it moved) in `previews/check/`. When the change is the point, look at them, then `scripts/check-previews.sh --update` re-records the goldens for you to commit. Adding a state to `PreviewRenderer` shows as `NEW` until you do. It's a local check for now: whether a CI runner draws the same pixels as a Mac with the fonts installed hasn't been settled.

## Logs and timings

Each request logs one line: the total time from letting go of the hotkey, the transcript, Herdr, whether Herdr's event stream was up, each model round, Holler's own tools, tokens, whether the answer was read aloud, and the request id. It never logs what you said. Use `/usr/bin/log`, since in zsh plain `log` is a shell built-in:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "com.assemblyai.holler" AND category == "Turn"'
```

`holler stats` sums those lines up: how many turns, each stage's p50, p95 and max, tokens in and out, rounds, and how often each tool was called. It covers the last 7 days unless you say `--since 24h` or `--last 20`. Settings reloads log under the `Settings` category, and the Dictation API's own timings under `Transcriber`, at info level, so stream them live:

```sh
/usr/bin/log stream --info --style compact --predicate 'subsystem == "com.assemblyai.holler" AND category == "Transcriber"'
```

To compare models on your own agents, `holler bench "summarise my agents" --models claude-haiku-5-5,claude-sonnet-5-5 --runs 2` runs the same request on each.

## Pull requests

- Keep each pull request to one change, with tests for anything in `HollerCore`.
- `scripts/test.sh` passes, and `scripts/check-previews.sh` too if you touched the note.
- The app's hotkey, mic and note can't be tested automatically, so say in the description what you tried by hand.
- Holler can send messages to, start, stop and close coding agents, so changes to actions, filters or redaction get a careful review. If you change what an action may do, update the safety model in [docs/reference.md](docs/reference.md).

## Security

Please don't open a public issue for a security problem. See [SECURITY.md](SECURITY.md).
