# Holler

A Mac menu-bar voice assistant: hold a key, ask about your Herdr agents, and read the answer in a floating note. Actions on agents run only once you confirm them, or after a short countdown you can cancel.

## Language

**Holler**:
The product: the menu-bar app, and the `holler` command-line tool that shares its core.

**Note**:
The floating panel where a conversation with Holler appears: your request, the answer and any confirm cards.
_Avoid_: Box, popup, overlay, window

**Pill**:
The note's compact form, showing only the mark and a status, used while you speak and while Holler works.
_Avoid_: Bar, capsule, island

**Mark**:
Holler's logo: five rounded bars that also show your voice level and when Holler is working. The same mark is used in the note, the menu bar and the app icon.
_Avoid_: Orb, icon, logo

**Action**:
Something Holler does in Herdr on your behalf: sending a message to an agent, starting one, interrupting one, or closing a tab Holler started. Once you've allowed it, a message to an idle agent and a start in a new tab run after a countdown; any other action waits on a confirm card. Until it runs, cancelling, closing the note, a request that fails or a correction drops it unsent.
_Avoid_: Pending action, command, task

**Confirm card**:
A card in the note that shows one action, waiting for you. It does nothing until you click its button (Send, Start, Interrupt or Close), or press Return while the button shows ↩.
_Avoid_: Action card, message card, start card

**Countdown**:
The few seconds before an action runs without a confirm card, shown on its card ("Sending in 3…"). Cancel or closing the note stops it, and so does Esc while Holler has the keyboard; Return runs it at once; any other key hands the keyboard, and Esc with it, back to your app while it carries on; and holding the key to speak pauses it until Holler answers: a correction then drops its action unsent, and otherwise it carries on from where it stopped, as it does when the request fails. The actions from one request share one countdown. At its end each action is checked again, and one that no longer qualifies, say because its agent started working, waits on its confirm card instead.
_Avoid_: Auto-send, undo window, grace period

**Jump**:
Switching Herdr to an agent's tab and pane, and bringing its terminal to the front, when you ask to see that agent ("show me the api agent"). It only moves your view, so unlike an action it needs no confirm card, and the note closes.
_Avoid_: Navigate, go-to

**Read aloud**:
Holler speaking an answer, in AssemblyAI's voice with the Mac's as fallback. Every answer is read aloud while **Read Answers Aloud** is on in the menu, which it is until you switch it off (ADR 0002); "just show me" keeps one answer silent, and with it off, "read it to me" speaks one. Cards, countdowns and alerts are never spoken. The note still shows the written answer.
_Avoid_: TTS, voice reply, narration

**Agent list**:
The rows the note shows the moment you let go of the key, one per agent Holler can see, with its status mark and how long it has been so, laid out as a summary is. It comes from the Herdr snapshot the request starts from, keeps up with Herdr's events while Holler works, and goes when the answer takes its place. Only the request that opens the note shows one; its rows can't be clicked.
_Avoid_: Instant list, live list, placeholder

**Alert**:
A quiet note Holler shows on its own when something you asked to be told about happens: "tell me when the api agent finishes" sets one, and the note opens, or grows, when that agent stops working, whether it finishes, ends by needing you or closes. Nothing is spoken. An alert outlives the note and the conversation; it ends when it fires or when Holler quits, and an agent takes one at a time.
_Avoid_: Notification, reminder, watch, subscription

**Conversation**:
Your recent requests and Holler's answers, which Holler remembers for 20 minutes after your last request, even once the note has closed, so a new question can carry on from earlier ones ("what about the api tab now?"). Only the last few exchanges are kept, never old agent output. Quitting Holler, or starting a new conversation from the menu, clears it.
_Avoid_: Memory, session, thread, history

**Follow-up**:
A further request in the same conversation, whether the note is still showing or you've reopened it.

**Golden image**:
A committed PNG of one preview state of the pill or note, in `Tests/Goldens/note/`, that `scripts/check-previews.sh` compares a fresh render against. Any pixel that changes fails the check; `--update` re-records them once a change is meant.
_Avoid_: Snapshot (that's `--snapshot`, a live answer captured from the real panel), reference image, baseline
