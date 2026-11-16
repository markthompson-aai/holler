# Answers are read aloud by default, as a setting you can switch off

Holler spoke an answer only when you asked to hear it ("read me the summary"), the rule it launched with, settled before Holler used AssemblyAI's text-to-speech. In daily use the spoken answer turned out to be the useful part: you ask while looking at something else, and the note is there to glance at afterwards. So the rule is reversed: a checkable menu item, **Read Answers Aloud**, on by default and kept across launches, gives every answer a spoken version. "Just show me" or "write me a summary" keeps one answer silent; with the setting off, "read it to me" still works for one. The model judges both from the request, as it did before.

The spoken version still comes from the same model call as the note, so nothing waits longer; it costs some output tokens and text-to-speech per answer. Cards, countdowns and alerts are never spoken: a card is read with the keyboard, and an alert is a quiet note by decision.

## Considered options

- **Keep speech on request only.** Nothing to switch off in a meeting, but you say "read it to me" on almost every request, which is the opposite of hands-free.
- **Always speak, with no setting.** Simplest, but a voice on every answer grates in a call or a shared office, and the Mac's mute key doesn't stop the model writing the spoken version.
- **A setting per kind of answer** (summaries aloud, explanations not). Nobody asked to separate them; one switch, with the per-request phrases, covers it.
- **Off by default.** Safer for a first run, but the setting exists because the voice is what's wanted; a first-run voice is also how you learn it's there.

## Consequences

- The system prompt's rule changes from "only when the user asks" to "as the request's settings say, unless the user asks otherwise for this one"; the model is told the setting with every request.
- VoiceOver stays quiet for a spoken answer, as before, so a screen reader and Holler never talk over each other. Pressing the hotkey or closing the note still stops speech.
- `GLOSSARY.md`'s **Read aloud** entry is rewritten; "speech only on request" no longer holds.
- The CLI's `ask` and `chat` keep the old behaviour: they print a spoken version only when the model wrote one on request.
