import Foundation
import Testing

@testable import HollerCore

final class FakeVoice: VoiceInput, @unchecked Sendable {
  private let lock = NSLock()
  private var _events: [String] = []
  var transcript: String
  var startError: (any Error)?
  /// How long the mic takes to go live, like a USB or Bluetooth device.
  var startDelay: Duration = .zero
  private var capturing = false

  init(transcript: String = "what are my agents up to?") { self.transcript = transcript }

  var events: [String] { lock.withLock { _events } }

  func start(keyTerms: [String]) async throws {
    lock.withLock { _events.append("start") }
    if let startError { throw startError }
    if startDelay > .zero { try await Task.sleep(for: startDelay) }
    lock.withLock { capturing = true }
  }

  /// Like Blurt's mic: `cancel()` stops whatever is capturing, whichever
  /// press started it, so a finish after a stray cancel gets nothing.
  func finish() async throws -> String {
    lock.withLock {
      _events.append("finish")
      defer { capturing = false }
      return capturing ? transcript : ""
    }
  }

  func cancel() async {
    lock.withLock {
      _events.append("cancel")
      capturing = false
    }
  }
}

/// Records what the controller asks to be spoken, and when it's stopped.
@MainActor
final class FakeSpeaker: VoiceOutput {
  var events: [String] = []
  /// Runs as speech starts, so a test can see what the note shows by then.
  var onSpeak: () -> Void = {}
  func speak(_ text: String) {
    events.append("speak: \(text)")
    onSpeak()
  }
  func stop() { events.append("stop") }
}

/// Answers after a delay, so a test can act while the assistant is thinking.
final class SlowGateway: ChatCompleting, @unchecked Sendable {
  func complete(_ request: ChatRequest) async throws -> ChatCompletion {
    try? await Task.sleep(for: .milliseconds(100))
    return ChatCompletion(message: .init(role: .assistant, content: "late answer"), usage: .init(), requestId: nil)
  }
}

/// Replays a script like `FakeGateway`, each answer after a delay.
final class SlowScriptedGateway: ChatCompleting, @unchecked Sendable {
  let script: FakeGateway
  init(_ script: [ChatMessage]) { self.script = FakeGateway(script) }
  func complete(_ request: ChatRequest) async throws -> ChatCompletion {
    try? await Task.sleep(for: .milliseconds(50))
    return try await script.complete(request)
  }
}

/// Fails every request, like LLM Gateway being down.
struct FailingGateway: ChatCompleting {
  struct Down: Error {}
  func complete(_ request: ChatRequest) async throws -> ChatCompletion { throw Down() }
}

@MainActor
@Suite struct AssistantControllerTests {
  let runner = FakeRunner()

  func controller(
    _ gateway: any ChatCompleting, voice: FakeVoice = FakeVoice(), speaker: FakeSpeaker? = nil,
    tapThreshold: Duration = .zero, clock: TestClock = TestClock()
  ) -> AssistantController {
    let herdr = Fixtures.client(runner)
    return AssistantController(voice: voice, speaker: speaker, herdr: herdr, tapThreshold: tapThreshold) {
      AssistantSession(
        gateway: gateway, herdr: herdr, configuration: .init(model: "test", prefetchLines: 0), clock: clock)
    }
  }

  /// Polls until `condition` holds, for work the controller runs in detached tasks.
  func eventually(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test func holdAndReleaseAsksAndShowsTheAnswer() async {
    let voice = FakeVoice()
    let controller = controller(FakeGateway([Fixtures.answer("**demo / main**: idle")]), voice: voice)

    controller.hotkeyDown()
    #expect(controller.phase == .listening && controller.isVisible)
    controller.hotkeyUp()
    #expect(controller.phase == .transcribing)
    await controller.settle()

    #expect(controller.phase == .ready)
    #expect(controller.exchanges.map(\.request) == ["what are my agents up to?"])
    #expect(controller.exchanges.first?.answer == "**demo / main**: idle")
    #expect(controller.exchanges.first?.activity == nil)
    #expect(voice.events == ["start", "finish"])
  }

  @Test func aQuickTapClosesTheNoteAndDropsTheAudio() async {
    let voice = FakeVoice()
    let controller = controller(FakeGateway([Fixtures.answer("hi")]), voice: voice, tapThreshold: .seconds(60))
    controller.ask("summarise")
    await controller.settle()
    #expect(controller.isVisible)

    controller.hotkeyDown()
    controller.hotkeyUp()
    #expect(controller.phase == .idle && controller.exchanges.isEmpty)
    await eventually { voice.events.contains("cancel") }
    // An instant tap cancels before the mic even opens.
    #expect(voice.events == ["cancel"])
  }

  @Test func followUpsShareOneSession() async {
    let gateway = FakeGateway([Fixtures.answer("first"), Fixtures.answer("second")])
    let controller = controller(gateway)
    controller.ask("summarise")
    await controller.settle()
    controller.ask("and the demo one?")
    await controller.settle()

    #expect(controller.exchanges.map(\.answer) == ["first", "second"])
    let secondRequest = gateway.requests[1].messages.compactMap(\.content).joined()
    #expect(secondRequest.contains("summarise") && secondRequest.contains("first"))
  }

  @Test func closingTheNoteKeepsTheConversation() async throws {
    let gateway = FakeGateway([Fixtures.answer("**demo / main**: idle."), Fixtures.answer("Yes, done.")])
    let controller = controller(gateway)
    controller.ask("how's the demo agent?")
    await controller.settle()
    controller.dismiss()
    controller.ask("is it done yet?")
    await controller.settle()

    #expect(controller.exchanges.map(\.request) == ["is it done yet?"])
    let messages = try #require(gateway.requests.last?.messages)
    #expect(messages.map(\.role) == [.system, .user, .assistant, .user])
    #expect(messages[2].content == "**demo / main**: idle.")
  }

  @Test func closingTheNoteDropsAWaitingCardAndTheNextRequestHearsOfIt() async throws {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#),
      Fixtures.answer("No, it wasn't sent."),
    ])
    let controller = controller(gateway)
    controller.ask("tell demo to carry on")
    await controller.settle()
    controller.dismiss()
    controller.ask("was the message sent?")
    await controller.settle()

    #expect(runner.prompts.isEmpty)
    let current = try #require(gateway.requests.last?.messages.last?.content)
    #expect(current.contains("a1 was dropped because the user closed the note without confirming it"))
  }

  @Test func aCardConfirmedJustBeforeClosingIsNotDropped() async throws {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#),
      Fixtures.answer("Yes, sent."),
    ])
    let controller = controller(gateway)
    controller.ask("tell demo to carry on")
    await controller.settle()
    controller.confirm("a1")
    controller.dismiss()
    await eventually { runner.prompts.count == 1 }
    controller.ask("was the message sent?")
    await controller.settle()

    #expect(runner.prompts == [["agent", "prompt", "w1:p1", "carry on"]])
    let current = try #require(gateway.requests.last?.messages.last?.content)
    #expect(current.contains("The user confirmed a1") && !current.contains("dropped"))
  }

  @Test func aNewConversationClosesTheNoteAndForgets() async throws {
    let gateway = FakeGateway([Fixtures.answer("**demo / main**: idle."), Fixtures.answer("Which agent?")])
    let controller = controller(gateway)
    controller.ask("how's the demo agent?")
    await controller.settle()
    controller.newConversation()
    #expect(controller.phase == .idle && controller.exchanges.isEmpty)
    controller.ask("is it done yet?")
    await controller.settle()

    #expect(gateway.requests.last?.messages.map(\.role) == [.system, .user])
  }

  @Test func aConfirmedCardShowsTheStatusTheSessionReports() async {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#)
    ])
    let controller = controller(gateway)
    controller.ask("tell demo to carry on")
    await controller.settle()
    #expect(controller.exchanges[0].actions.map(\.status) == [.waiting(because: nil)])

    runner.snapshot = Fixtures.snapshotWithoutDemoAgent
    controller.confirm("a1")
    await controller.settle()
    #expect(controller.exchanges[0].actions[0].status == .failed("no readable agent in pane w1:p1"))
    #expect(!controller.hasWaitingActions)
  }

  @Test func returnConfirmsTheNewestWaitingCardOnly() async {
    let gateway = FakeGateway([
      ChatMessage(
        role: .assistant, content: nil,
        toolCalls: [
          ToolCall(id: "c1", name: "prompt_agent", arguments: #"{"pane_id":"w1:p1","message":"carry on"}"#),
          ToolCall(id: "c2", name: "prompt_agent", arguments: #"{"pane_id":"w1:p1","message":"also this"}"#),
        ])
    ])
    let controller = controller(gateway)
    controller.ask("tell demo to carry on")
    await controller.settle()
    #expect(controller.newestWaitingAction == "a2")

    controller.confirmNewest()
    await controller.settle()
    #expect(controller.exchanges[0].actions.map(\.status) == [.waiting(because: nil), .done])
    #expect(runner.prompts == [["agent", "prompt", "w1:p1", "also this"]])
    #expect(controller.newestWaitingAction == "a1")

    controller.cancel("a1")
    controller.confirmNewest()
    await controller.settle()
    #expect(controller.exchanges[0].actions.map(\.status) == [.cancelled, .done])
    #expect(runner.prompts.count == 1)
    #expect(!controller.hasWaitingActions)
  }

  @Test func anotherKeyHandsTheKeyboardBackUntilTheNextCard() async {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#),
      Fixtures.answer("**demo / main**: idle."),
      Fixtures.toolCall("c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"run the tests"}"#),
      Fixtures.toolCall("c3", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#),
    ])
    let controller = controller(gateway)
    controller.ask("tell demo to carry on")
    await controller.settle()
    #expect(controller.holdsKeyboard)

    controller.handBackKeyboard()
    #expect(!controller.holdsKeyboard && controller.newestWaitingAction == "a1")

    // An answer without a card leaves the keyboard with your app.
    controller.ask("how's demo?")
    await controller.settle()
    #expect(!controller.holdsKeyboard)

    controller.ask("and tell it to run the tests")
    await controller.settle()
    #expect(controller.holdsKeyboard && controller.newestWaitingAction == "a2")

    controller.handBackKeyboard()
    controller.dismiss()
    controller.ask("tell demo to carry on")
    await controller.settle()
    #expect(controller.holdsKeyboard)
  }

  @Test func aCorrectionMarksTheCardItReplaces() async {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#),
      Fixtures.toolCall("c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"stop","replaces":"a1"}"#),
    ])
    let controller = controller(gateway)
    controller.ask("tell demo to carry on")
    await controller.settle()
    controller.ask("actually, tell it to stop")
    await controller.settle()

    #expect(controller.exchanges.map { $0.actions.map(\.status) } == [[.replaced], [.waiting(because: nil)]])
    #expect(controller.newestWaitingAction == "a2")
    controller.confirmNewest()
    await controller.settle()
    #expect(runner.prompts == [["agent", "prompt", "w1:p1", "stop"]])
    #expect(!controller.hasWaitingActions)
  }

  @Test func dismissingWhileThinkingDropsTheLateAnswer() async {
    let controller = controller(SlowGateway())
    controller.ask("summarise")
    await eventually { controller.phase == .thinking }
    controller.dismiss()
    try? await Task.sleep(for: .milliseconds(250))

    #expect(controller.phase == .idle)
    #expect(controller.exchanges.isEmpty)
  }

  @Test func anActionInALateAnswerIsDroppedUnsent() async throws {
    let gateway = SlowScriptedGateway([
      Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#),
      Fixtures.answer("No."),
    ])
    let controller = controller(gateway)
    controller.ask("tell demo to carry on")
    await eventually { controller.phase == .thinking }
    controller.dismiss()
    try? await Task.sleep(for: .milliseconds(250))
    controller.ask("was the message sent?")
    await controller.settle()

    #expect(runner.prompts.isEmpty)
    let current = try #require(gateway.script.requests.last?.messages.last?.content)
    #expect(current.contains("a1 was dropped because the user closed the note without confirming it"))
  }

  // MARK: - Cutting in

  @Test func holdingTheKeyWhileItThinksDropsTheRequestAndListens() async {
    let voice = FakeVoice()
    let controller = controller(SlowGateway(), voice: voice)
    controller.ask("summarise")
    await eventually { controller.phase == .thinking }

    controller.hotkeyDown()
    await eventually { controller.phase == .listening }
    #expect(controller.exchanges.isEmpty && controller.form == .pill)
    await eventually { controller.isMicLive }
    controller.hotkeyUp()
    await controller.settle()
    try? await Task.sleep(for: .milliseconds(150))

    #expect(controller.exchanges.map(\.request) == ["what are my agents up to?"])
    #expect(controller.exchanges.map(\.answer) == ["late answer"])
    #expect(controller.phase == .ready)
  }

  @Test func cuttingInKeepsEarlierExchangesInTheNote() async {
    let gateway = SlowScriptedGateway([Fixtures.answer("**demo / main**: idle."), Fixtures.answer("dropped")])
    let controller = controller(gateway)
    controller.ask("how's demo?")
    await controller.settle()
    controller.ask("and the api one?")
    await eventually { controller.phase == .thinking }

    controller.hotkeyDown()
    await eventually { controller.phase == .listening }
    #expect(controller.exchanges.map(\.request) == ["how's demo?"])
    #expect(controller.form == .note && controller.status != nil)
    controller.hotkeyCancelled()
  }

  @Test func cuttingInDropsTheCardsTheRequestQueuedUnsent() async throws {
    // The first request is held at the model until the cut-in has dropped
    // it, so its late answer can't land first on a slow machine.
    let gateway = GatedGateway(
      [
        Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#),
        Fixtures.answer("No."),
      ], holding: 1)
    let controller = controller(gateway, voice: FakeVoice(transcript: "was the message sent?"))
    controller.ask("tell demo to carry on")
    await gateway.waitUntilHeld()
    controller.hotkeyDown()
    await eventually { controller.phase == .listening }
    gateway.release()  // the dropped request's late answer comes back
    await eventually { controller.isMicLive }
    controller.hotkeyUp()
    await controller.settle()

    #expect(runner.prompts.isEmpty && !controller.hasWaitingActions)
    #expect(controller.exchanges.map(\.request) == ["was the message sent?"])
    let current = try #require(gateway.script.requests.last?.messages.last?.content)
    #expect(current.contains("a1 was dropped"))
  }

  @Test func holdingTheKeyWhileItTranscribesDropsTheRecordingAndListens() async {
    let voice = FakeVoice()
    voice.startDelay = .milliseconds(50)
    let controller = controller(FakeGateway([Fixtures.answer("ok")]), voice: voice)
    // Let go while the mic is still connecting, then hold again.
    controller.hotkeyDown()
    controller.hotkeyUp()
    #expect(controller.phase == .transcribing)
    controller.hotkeyDown()
    await eventually { controller.isMicLive }
    controller.hotkeyUp()
    await controller.settle()

    #expect(voice.events == ["start", "cancel", "start", "finish"])
    #expect(controller.exchanges.map(\.request) == ["what are my agents up to?"])
    #expect(controller.exchanges.map(\.answer) == ["ok"])
  }

  @Test func closingTheNoteWhileTheMicIsStillConnectingStopsIt() async {
    let voice = FakeVoice()
    voice.startDelay = .milliseconds(50)
    let controller = controller(FakeGateway([Fixtures.answer("ok")]), voice: voice)
    // Let go while the mic is still connecting, then close the note (Esc).
    controller.hotkeyDown()
    await eventually { voice.events.contains("start") }
    controller.hotkeyUp()
    #expect(controller.phase == .transcribing)
    controller.dismiss()
    await controller.settle()
    await eventually { voice.events.contains("cancel") }

    #expect(controller.phase == .idle && controller.exchanges.isEmpty)
    #expect(voice.events == ["start", "cancel"])
  }

  @Test func closingTheNoteOnceTheMicIsUpLeavesTheFinishToTheRequest() async {
    let voice = FakeVoice()
    let controller = controller(SlowGateway(), voice: voice)
    controller.hotkeyDown()
    await eventually { controller.isMicLive }
    controller.hotkeyUp()
    await eventually { voice.events.contains("finish") }
    controller.dismiss()
    await controller.settle()

    #expect(controller.phase == .idle)
    // Finishing stopped the mic, so no second teardown is sent after it.
    #expect(voice.events == ["start", "finish"])
  }

  @Test func aShortcutBeforeCuttingInLeavesTheRequestRunning() async {
    let voice = FakeVoice()
    let controller = controller(SlowGateway(), voice: voice, tapThreshold: .seconds(60))
    controller.ask("summarise")
    await eventually { controller.phase == .thinking }
    controller.hotkeyDown()
    controller.hotkeyCancelled()
    await controller.settle()

    #expect(controller.phase == .ready)
    #expect(controller.exchanges.map(\.answer) == ["late answer"])
    #expect(voice.events.isEmpty)
  }

  @Test func aTapWhileItThinksClosesTheNote() async {
    let voice = FakeVoice()
    let controller = controller(SlowGateway(), voice: voice, tapThreshold: .seconds(60))
    controller.ask("summarise")
    await eventually { controller.phase == .thinking }
    controller.hotkeyDown()
    #expect(controller.phase == .thinking)
    controller.hotkeyUp()
    try? await Task.sleep(for: .milliseconds(150))

    #expect(controller.phase == .idle && controller.exchanges.isEmpty)
    #expect(voice.events.isEmpty)
  }

  // MARK: - Typing a question

  @Test func aTypedQuestionDropsThePressBeingHeard() async {
    let voice = FakeVoice()
    let controller = controller(FakeGateway([Fixtures.answer("ok")]), voice: voice)
    controller.hotkeyDown()
    await eventually { controller.isMicLive }
    controller.ask("summarise")
    controller.hotkeyUp()
    await controller.settle()
    await eventually { voice.events.contains("cancel") }

    #expect(!voice.events.contains("finish"))
    #expect(controller.exchanges.map(\.request) == ["summarise"] && controller.phase == .ready)
  }

  @Test func aTypedQuestionReplacesTheRequestInProgress() async {
    let controller = controller(SlowGateway())
    controller.ask("summarise")
    await eventually { controller.phase == .thinking }
    controller.ask("just the api agent")
    await controller.settle()
    try? await Task.sleep(for: .milliseconds(150))

    #expect(controller.exchanges.map(\.request) == ["just the api agent"])
    #expect(controller.exchanges.map(\.answer) == ["late answer"])
  }

  @Test func aTypedQuestionIsAFollowUpInAnOpenNote() async {
    let controller = controller(FakeGateway([Fixtures.answer("first"), Fixtures.answer("second")]))
    controller.ask("summarise")
    await controller.settle()
    controller.ask("and the api one?")
    await controller.settle()
    #expect(controller.exchanges.map(\.answer) == ["first", "second"])
  }

  // MARK: - Reopening

  @Test func reopeningShowsTheLastNoteAgainWithoutItsCards() async throws {
    let gateway = FakeGateway([
      Fixtures.answer("**demo / main**: idle."),
      Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#),
      Fixtures.answer("No, it wasn't sent."),
    ])
    let controller = controller(gateway)
    #expect(!controller.canReopen)
    controller.ask("how's demo?")
    await controller.settle()
    controller.ask("tell it to carry on")
    await controller.settle()
    controller.dismiss()
    #expect(controller.canReopen)

    controller.reopen()
    await controller.settle()
    #expect(controller.phase == .ready && controller.form == .note && !controller.canReopen)
    #expect(controller.exchanges.map(\.request) == ["how's demo?", "tell it to carry on"])
    #expect(controller.exchanges.map(\.answer) == ["**demo / main**: idle.", "Ready to send to demo / main."])
    #expect(controller.exchanges.map(\.actions) == [[], []])
    #expect(controller.exchanges.map(\.cardsLeftOut) == [0, 1])
    #expect(!controller.hasWaitingActions && !controller.holdsKeyboard)

    // A follow-up carries on in the reopened note.
    controller.ask("was it sent?")
    await controller.settle()
    #expect(controller.exchanges.map(\.request) == ["how's demo?", "tell it to carry on", "was it sent?"])
    #expect(runner.prompts.isEmpty)
    let current = try #require(gateway.requests.last?.messages.last?.content)
    #expect(current.contains("a1 was dropped because the user closed the note"))
  }

  @Test func onlyAnsweredExchangesAreReopened() async {
    let gateway = FakeGateway([Fixtures.answer("**demo / main**: idle.")], failing: [2])
    let controller = controller(gateway)
    controller.ask("how's demo?")
    await controller.settle()
    controller.ask("and now?")
    await controller.settle()
    controller.dismiss()
    controller.reopen()
    await controller.settle()
    #expect(controller.exchanges.map(\.request) == ["how's demo?"])
    #expect(controller.phase == .ready)
  }

  @Test func aNoteThatClosesWithNothingAnsweredLeavesTheLastOneToReopen() async {
    let controller = controller(FakeGateway([Fixtures.answer("first")]), tapThreshold: .seconds(60))
    controller.ask("summarise")
    await controller.settle()
    controller.dismiss()
    // A tap on its own opens and closes nothing worth keeping.
    controller.hotkeyDown()
    controller.hotkeyUp()
    #expect(controller.canReopen)
    controller.reopen()
    await controller.settle()
    #expect(controller.exchanges.map(\.answer) == ["first"])
  }

  @Test func aNewConversationLeavesNothingToReopen() async {
    let controller = controller(FakeGateway([Fixtures.answer("first")]))
    controller.ask("summarise")
    await controller.settle()
    controller.newConversation()
    #expect(!controller.canReopen)
    controller.reopen()
    await controller.settle()
    #expect(controller.phase == .idle)
  }

  @Test func reopeningAfterTheConversationEndedSaysSo() async {
    let clock = TestClock()
    let controller = controller(FakeGateway([Fixtures.answer("first")]), clock: clock)
    controller.ask("summarise")
    await controller.settle()
    controller.dismiss()
    clock.advance(by: .seconds(20 * 60 + 1))

    controller.reopen()
    await controller.settle()
    #expect(controller.exchanges.isEmpty && controller.form == .note)
    #expect(controller.notice?.contains("conversation has ended") == true)
    controller.dismiss()
    #expect(!controller.canReopen)
  }

  @Test func silenceClosesAnEmptyNoteButKeepsAConversation() async {
    let voice = FakeVoice(transcript: "  ")
    let controller = controller(FakeGateway([Fixtures.answer("hi")]), voice: voice)
    controller.hotkeyDown()
    controller.hotkeyUp()
    await controller.settle()
    #expect(controller.phase == .idle)

    controller.ask("summarise")
    await controller.settle()
    controller.hotkeyDown()
    controller.hotkeyUp()
    await controller.settle()
    #expect(controller.phase == .ready)
    #expect(controller.exchanges.count == 1)
    #expect(controller.notice?.contains("Didn't catch that") == true)
  }

  @Test func aShortcutWhileHoldingCancelsListening() async {
    let voice = FakeVoice()
    let controller = controller(FakeGateway([]), voice: voice)
    controller.hotkeyDown()
    controller.hotkeyCancelled()
    #expect(controller.phase == .idle)
    await eventually { voice.events.contains("cancel") }
    #expect(!voice.events.contains("finish"))
  }

  @Test func aQuickSecondPressIsNotCancelledByTheFirstPressCleanup() async {
    let voice = FakeVoice()
    // Wide margins on the real clock, so a slow CI runner can't turn the
    // 15 ms tap into a press or let the mic connect before it.
    voice.startDelay = .milliseconds(300)
    let controller = controller(FakeGateway([Fixtures.answer("ok")]), voice: voice, tapThreshold: .milliseconds(300))

    controller.hotkeyDown()
    try? await Task.sleep(for: .milliseconds(15))
    controller.hotkeyUp()  // a tap while the mic is still connecting
    controller.hotkeyDown()  // straight back in
    try? await Task.sleep(for: .milliseconds(600))
    controller.hotkeyUp()
    await controller.settle()

    #expect(controller.exchanges.map(\.request) == ["what are my agents up to?"])
    #expect(voice.events == ["start", "cancel", "start", "finish"])
  }

  @Test func chimesComeInPairsAndOnlyForLiveQuestions() async {
    var cues: [String] = []
    let voice = FakeVoice()
    let controller = controller(FakeGateway([Fixtures.answer("ok")]), voice: voice)
    controller.onListeningStarted = { cues.append("start") }
    controller.onListeningEnded = { cues.append("stop") }

    // A shortcut before the mic is live: silent.
    voice.startDelay = .milliseconds(50)
    controller.hotkeyDown()
    controller.hotkeyCancelled()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(cues.isEmpty)

    // A real question: start once live, stop on release.
    voice.startDelay = .zero
    controller.hotkeyDown()
    #expect(!controller.isMicLive)
    await eventually { controller.isMicLive }
    controller.hotkeyUp()
    await controller.settle()
    #expect(cues == ["start", "stop"])
  }

  @Test func microphoneFailureIsShownInTheNote() async {
    let voice = FakeVoice()
    voice.startError = CommandError.launchFailed("no microphone")
    let controller = controller(FakeGateway([]), voice: voice)
    controller.hotkeyDown()
    controller.hotkeyUp()
    await controller.settle()
    #expect(controller.phase == .failed("could not launch: no microphone"))
    #expect(controller.form == .note && controller.status == nil && controller.mark == .still)
  }

  // MARK: - Pill and note

  @Test func aPressShowsThePillUntilThereIsSomethingToRead() async {
    let voice = FakeVoice()
    voice.startDelay = .milliseconds(20)
    let controller = controller(FakeGateway([Fixtures.answer("**1 idle.**\n\n- **demo / main**: idle")]), voice: voice)
    #expect(controller.form == .hidden && controller.status == nil)

    controller.hotkeyDown()
    #expect(controller.form == .pill && controller.status == "Connecting…" && controller.mark == .working)
    await eventually { controller.isMicLive }
    #expect(controller.form == .pill && controller.status == "Listening…" && controller.mark == .listening)

    controller.hotkeyUp()
    #expect(controller.form == .pill && controller.mark == .working)
    await controller.settle()
    #expect(controller.form == .note && controller.status == nil && controller.mark == .still)

    controller.dismiss()
    #expect(controller.form == .hidden)
  }

  @Test func aFollowUpKeepsTheNoteOpenWithItsStatus() async {
    let controller = controller(SlowGateway())
    controller.ask("what are my agents up to?")
    await controller.settle()
    #expect(controller.form == .note)

    controller.hotkeyDown()
    await eventually { controller.isMicLive }
    #expect(controller.form == .note && controller.status == "Listening…" && controller.mark == .listening)
    controller.hotkeyUp()
    await eventually { controller.phase == .thinking }
    #expect(controller.form == .note && controller.status == "Checking your agents…" && controller.mark == .working)
  }

  @Test func aFollowUpAfterAnErrorKeepsTheNoteOpen() async {
    let controller = controller(FailingGateway())
    controller.ask("what are my agents up to?")
    await controller.settle()
    guard case .failed = controller.phase else {
      Issue.record("expected a failure, got \(controller.phase)")
      return
    }
    #expect(controller.form == .note)

    controller.hotkeyDown()
    #expect(controller.form == .note)
    controller.hotkeyCancelled()
    #expect(controller.phase == .ready && controller.form == .note)
  }

  @Test func anAnswerIsReadAloudOnlyWhenTheModelAsks() async {
    let speaker = FakeSpeaker()
    let gateway = FakeGateway([
      Fixtures.answer("**1 idle.**"),
      Fixtures.answer("**1 idle.**\n<read_aloud>The demo agent is idle.</read_aloud>"),
    ])
    let controller = controller(gateway, speaker: speaker)
    controller.ask("summarise")
    await controller.settle()
    #expect(speaker.events.isEmpty)
    #expect(controller.exchanges.last?.readAloud == false)

    controller.ask("read that to me")
    await controller.settle()
    #expect(speaker.events == ["speak: The demo agent is idle."])
    #expect(controller.exchanges.last?.answer == "**1 idle.**")
    // So the note can tell a screen reader to stay quiet while Holler speaks.
    #expect(controller.exchanges.last?.readAloud == true)
  }

  @Test func pressingTheKeyOrClosingTheNoteStopsSpeech() async {
    let speaker = FakeSpeaker()
    let controller = controller(FakeGateway([Fixtures.answer("ok")]), speaker: speaker)
    controller.ask("summarise")
    await controller.settle()

    controller.hotkeyDown()
    #expect(speaker.events == ["stop"])
    controller.dismiss()
    #expect(speaker.events == ["stop", "stop"])
  }

  @Test func theNoteShowsTheAnswerBeforeSpeechStarts() async {
    let speaker = FakeSpeaker()
    let controller = controller(
      FakeGateway([Fixtures.answer("**1 idle.**\n<read_aloud>One idle.</read_aloud>")]), speaker: speaker)
    var shownWhenSpeaking: String?
    speaker.onSpeak = { shownWhenSpeaking = controller.exchanges.last?.answer }
    controller.ask("read me the summary")
    await controller.settle()
    #expect(shownWhenSpeaking == "**1 idle.**")
    #expect(controller.form == .note)
  }
}
