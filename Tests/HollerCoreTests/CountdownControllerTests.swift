import Foundation
import Testing

@testable import HollerCore

/// The countdown as the note sees it: the card counts down, Return runs it at
/// once, Cancel, Esc and closing the note stop it, and other keys hand the
/// keyboard back while it carries on (ADR 0001).
@MainActor
@Suite struct CountdownControllerTests {
  let runner = FakeRunner()
  let clock = TestClock()

  func controller(_ gateway: any ChatCompleting, voice: FakeVoice = FakeVoice(), allowed: Bool = true) -> AssistantController {
    let herdr = Fixtures.client(runner)
    let clock = clock
    let controller = AssistantController(voice: voice, herdr: herdr, tapThreshold: .zero) {
      AssistantSession(gateway: gateway, herdr: herdr, configuration: .init(model: "test", prefetchLines: 0), clock: clock)
    }
    controller.runsSimpleActionsWithoutACard = allowed
    return controller
  }

  /// Polls until `condition` holds, for work the controller runs in detached tasks.
  func eventually(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  static let send = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#)
  static let sent = [["agent", "prompt", "w1:p1", "carry on"]]

  var cardStatuses: (AssistantController) -> [ActionStatus] { { $0.exchanges.flatMap(\.actions).map(\.status) } }

  @Test func aSendCountsDownOnItsCardThenSends() async {
    let controller = controller(FakeGateway([Self.send]))
    controller.ask("tell demo to carry on")
    await controller.settle()
    await eventually { cardStatuses(controller) == [.countingDown(3)] }
    #expect(controller.exchanges.last?.answer == "Sending to demo / main.")
    #expect(cardStatuses(controller) == [.countingDown(3)])
    #expect(controller.newestWaitingAction == "a1" && controller.holdsKeyboard)

    clock.advance(by: .seconds(1))
    await eventually { cardStatuses(controller) == [.countingDown(2)] }
    #expect(cardStatuses(controller) == [.countingDown(2)] && runner.prompts.isEmpty)
    clock.advance(by: .seconds(2))
    await eventually { cardStatuses(controller) == [.done] }

    #expect(cardStatuses(controller) == [.done])
    #expect(runner.prompts == Self.sent)
    #expect(!controller.hasWaitingActions && !controller.holdsKeyboard)
    #expect(controller.phase == .ready)
  }

  @Test func withTheSettingOffASendWaitsAsBefore() async {
    let controller = controller(FakeGateway([Self.send]), allowed: false)
    controller.ask("tell demo to carry on")
    await controller.settle()
    await eventually { cardStatuses(controller) == [.waiting(because: nil)] }
    #expect(controller.exchanges.last?.answer == "Ready to send to demo / main.")
    #expect(cardStatuses(controller) == [.waiting(because: nil)])

    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(cardStatuses(controller) == [.waiting(because: nil)] && runner.prompts.isEmpty)
    #expect(controller.holdsKeyboard)
  }

  @Test func aStartCountsDownOnItsCardThenStarts() async throws {
    let folder = try Fixtures.folder()
    let controller = controller(FakeGateway([ActionStatusTests.start(in: folder)]))
    controller.ask("start an agent to run the tests")
    await controller.settle()
    await eventually { cardStatuses(controller) == [.countingDown(3)] }
    #expect(controller.exchanges.last?.answer == "Starting Claude in demo / tests.")
    #expect(cardStatuses(controller) == [.countingDown(3)])
    #expect(controller.exchanges.last?.actions.first?.content.words.countdown == "Starting in")
    #expect(controller.exchanges.last?.actions.first?.content.words.runNow == "Start now")

    clock.advance(by: .seconds(3))
    await eventually { cardStatuses(controller) == [.done] }
    #expect(cardStatuses(controller) == [.done])
    #expect(runner.calls.contains(["agent", "start", "tests", "--kind", "claude", "--pane", "w1:p9", "--timeout", "30000"]))
    #expect(runner.prompts == [["agent", "prompt", "w1:p9", "Run the tests."]])
  }

  @Test func aSendToAWorkingAgentWaitsAndItsCardSaysWhy() async {
    runner.snapshot = InterruptAgentTests.snapshotWorking
    let controller = controller(FakeGateway([Self.send]))
    controller.ask("tell demo to carry on")
    await controller.settle()
    await eventually { cardStatuses(controller) == [.waiting(because: "main is working, so this waits for you.")] }
    #expect(controller.exchanges.last?.answer == "Ready to send to demo / main.")
    #expect(cardStatuses(controller) == [.waiting(because: "main is working, so this waits for you.")])
  }

  @Test func withTheSettingOffAWorkingAgentsCardSaysNothingMore() async {
    runner.snapshot = InterruptAgentTests.snapshotWorking
    let controller = controller(FakeGateway([Self.send]), allowed: false)
    controller.ask("tell demo to carry on")
    await controller.settle()
    await eventually { cardStatuses(controller) == [.waiting(because: nil)] }
    #expect(cardStatuses(controller) == [.waiting(because: nil)])
  }

  @Test func returnDuringTheCountdownSendsAtOnce() async {
    let controller = controller(FakeGateway([Self.send]))
    controller.ask("tell demo to carry on")
    await controller.settle()
    clock.advance(by: .seconds(1))
    await eventually { cardStatuses(controller) == [.countingDown(2)] }

    controller.confirmNewest()
    await controller.settle()
    await eventually { cardStatuses(controller) == [.done] }
    #expect(cardStatuses(controller) == [.done])
    #expect(runner.prompts == Self.sent)

    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.prompts == Self.sent)
  }

  @Test func cancelDuringTheCountdownSendsNothing() async {
    let controller = controller(FakeGateway([Self.send]))
    controller.ask("tell demo to carry on")
    await controller.settle()

    controller.cancel("a1")
    await controller.settle()
    await eventually { cardStatuses(controller) == [.cancelled] }
    #expect(cardStatuses(controller) == [.cancelled])
    #expect(!controller.hasWaitingActions && !controller.holdsKeyboard)
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(cardStatuses(controller) == [.cancelled] && runner.prompts.isEmpty)
  }

  @Test func closingTheNoteDuringTheCountdownSendsNothing() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("No, you closed the note.")])
    let controller = controller(gateway)
    controller.ask("tell demo to carry on")
    await controller.settle()
    clock.advance(by: .seconds(1))
    await eventually { cardStatuses(controller) == [.countingDown(2)] }

    // Esc closes the note.
    controller.dismiss()
    await controller.settle()
    #expect(controller.phase == .idle)
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.prompts.isEmpty)

    controller.ask("was it sent?")
    await controller.settle()
    #expect(runner.prompts.isEmpty && cardStatuses(controller).isEmpty)
    let current = try #require(gateway.requests.last?.messages.last?.content)
    #expect(current.contains("a1 was cancelled during the countdown, when the user closed the note; nothing was done."))
  }

  /// Closing the note stops its countdown at once, even while an earlier
  /// confirm is still waiting on Herdr.
  @Test func closingTheNoteWhileAConfirmIsStuckStillStopsTheCountdown() async throws {
    let gateway = FakeGateway([Self.twoSends, Fixtures.answer("Only the first went.")])
    let controller = controller(gateway)
    controller.ask("tell demo to carry on, then run the tests")
    await controller.settle()
    let gate = Gate()
    runner.promptGate = gate

    controller.confirm("a1")
    await eventually { runner.prompts.count == 1 }
    controller.dismiss()
    clock.advance(by: .seconds(3))
    try? await Task.sleep(for: .milliseconds(50))
    gate.open()
    await controller.settle()
    #expect(runner.prompts == Self.sent)

    controller.ask("what went?")
    await controller.settle()
    let current = try #require(gateway.requests.last?.messages.last?.content)
    #expect(current.contains("a2 was cancelled during the countdown"))
  }

  @Test func anotherKeyHandsTheKeyboardBackWhileTheCountdownCarriesOn() async {
    let controller = controller(FakeGateway([Self.send]))
    controller.ask("tell demo to carry on")
    await controller.settle()
    #expect(controller.holdsKeyboard)

    controller.handBackKeyboard()
    #expect(!controller.holdsKeyboard && controller.hasWaitingActions)
    clock.advance(by: .seconds(1))
    await eventually { cardStatuses(controller) == [.countingDown(2)] }
    #expect(!controller.holdsKeyboard)

    clock.advance(by: .seconds(2))
    await eventually { cardStatuses(controller) == [.done] }
    #expect(runner.prompts == Self.sent)
  }

  @Test func anAgentThatStartsWorkingDuringTheCountdownGetsAWaitingCard() async {
    let controller = controller(FakeGateway([Self.send]))
    controller.ask("tell demo to carry on")
    await controller.settle()
    runner.snapshot = InterruptAgentTests.snapshotWorking

    clock.advance(by: .seconds(3))
    let fellBack = ActionStatus.waiting(because: "main started working, so this waits for you.")
    await eventually { cardStatuses(controller) == [fellBack] }
    #expect(cardStatuses(controller) == [fellBack] && runner.prompts.isEmpty)
    #expect(controller.hasWaitingActions && controller.newestWaitingAction == "a1")

    controller.confirmNewest()
    await controller.settle()
    await eventually { cardStatuses(controller) == [.done] }
    #expect(cardStatuses(controller) == [.done])
    #expect(runner.prompts == Self.sent)
  }

  static let twoSends = ChatMessage(
    role: .assistant, content: nil,
    toolCalls: [
      ToolCall(id: "c1", name: "prompt_agent", arguments: #"{"pane_id":"w1:p1","message":"carry on"}"#),
      ToolCall(id: "c2", name: "prompt_agent", arguments: #"{"pane_id":"w1:p1","message":"then run the tests"}"#),
    ])

  @Test func twoSendsShareOneCountdownEachWithItsOwnCancel() async {
    let controller = controller(FakeGateway([Self.twoSends]))
    controller.ask("tell demo to carry on, then run the tests")
    await controller.settle()
    await eventually { cardStatuses(controller) == [.countingDown(3), .countingDown(3)] }
    #expect(cardStatuses(controller) == [.countingDown(3), .countingDown(3)])
    #expect(controller.newestWaitingAction == "a2")

    controller.cancel("a1")
    await controller.settle()
    await eventually { cardStatuses(controller) == [.cancelled, .countingDown(3)] }
    #expect(cardStatuses(controller) == [.cancelled, .countingDown(3)])
    clock.advance(by: .seconds(3))
    await eventually { cardStatuses(controller) == [.cancelled, .done] }
    #expect(runner.prompts == [["agent", "prompt", "w1:p1", "then run the tests"]])
  }

  // MARK: - Holding the key to speak pauses it

  static let correction = Fixtures.toolCall(
    "c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"stop instead","replaces":"a1"}"#)
  static let addition = Fixtures.toolCall("c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"and run the tests"}"#)

  /// A controller whose note shows a1 counting down, ticked down to 2.
  func countedTo2(_ gateway: any ChatCompleting, voice: FakeVoice = FakeVoice()) async -> AssistantController {
    let controller = controller(gateway, voice: voice)
    controller.ask("tell demo to carry on")
    await controller.settle()
    clock.advance(by: .seconds(1))
    await eventually { cardStatuses(controller) == [.countingDown(2)] }
    return controller
  }

  static func failed(_ controller: AssistantController) -> Bool {
    if case .failed = controller.phase { true } else { false }
  }

  /// Holds the key until the mic is live, so the press is a question.
  func press(_ controller: AssistantController) async {
    controller.hotkeyDown()
    await eventually { controller.isMicLive }
  }

  @Test func pressingTheKeyPausesTheCountdownBeforeTheMicIsLive() async {
    let voice = FakeVoice()
    voice.startDelay = .seconds(5)
    let controller = await countedTo2(FakeGateway([Self.send]), voice: voice)

    controller.hotkeyDown()
    await eventually { cardStatuses(controller) == [.paused] }
    #expect(cardStatuses(controller) == [.paused] && !controller.isMicLive)
    // A paused card is still the one Return runs.
    #expect(controller.newestWaitingAction == "a1" && controller.hasWaitingActions)
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(cardStatuses(controller) == [.paused] && runner.prompts.isEmpty)
    controller.dismiss()
  }

  @Test func anAdditionLetsThePausedCountdownResumeAndAddsItsOwn() async {
    let controller = await countedTo2(
      FakeGateway([Self.send, Self.addition]), voice: FakeVoice(transcript: "and also tell it to run the tests"))

    await press(controller)
    #expect(cardStatuses(controller) == [.paused])
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(cardStatuses(controller) == [.paused] && runner.prompts.isEmpty)

    controller.hotkeyUp()
    await controller.settle()
    await eventually { cardStatuses(controller) == [.countingDown(2), .countingDown(3)] }
    #expect(cardStatuses(controller) == [.countingDown(2), .countingDown(3)])
    clock.advance(by: .seconds(2))
    await eventually { cardStatuses(controller) == [.done, .countingDown(1)] }
    #expect(runner.prompts == Self.sent)
    clock.advance(by: .seconds(1))
    await eventually { cardStatuses(controller) == [.done, .done] }
    #expect(runner.prompts == Self.sent + [["agent", "prompt", "w1:p1", "and run the tests"]])
  }

  @Test func aCorrectionReplacesThePausedActionAndCountsFrom3() async {
    let controller = await countedTo2(
      FakeGateway([Self.send, Self.correction]), voice: FakeVoice(transcript: "actually, tell it to stop instead"))

    await press(controller)
    controller.hotkeyUp()
    await controller.settle()
    await eventually { cardStatuses(controller) == [.replaced, .countingDown(3)] }
    #expect(cardStatuses(controller) == [.replaced, .countingDown(3)])
    clock.advance(by: .seconds(2))
    await eventually { cardStatuses(controller) == [.replaced, .countingDown(1)] }
    #expect(runner.prompts.isEmpty)
    clock.advance(by: .seconds(1))
    await eventually { cardStatuses(controller) == [.replaced, .done] }
    #expect(runner.prompts == [["agent", "prompt", "w1:p1", "stop instead"]])
  }

  @Test func aFailedFollowUpResumesTheCountdown() async {
    let controller = await countedTo2(FakeGateway([Self.send], failing: [2]))

    await press(controller)
    controller.hotkeyUp()
    await controller.settle()
    await eventually { cardStatuses(controller) == [.countingDown(2)] }
    #expect(Self.failed(controller))
    #expect(cardStatuses(controller) == [.countingDown(2)])
    clock.advance(by: .seconds(2))
    await eventually { cardStatuses(controller) == [.done] }
    #expect(runner.prompts == Self.sent)
  }

  @Test func aMicThatFailsToStartResumesTheCountdown() async {
    let voice = FakeVoice()
    voice.startError = CommandError.launchFailed("no microphone")
    let controller = await countedTo2(FakeGateway([Self.send]), voice: voice)

    controller.hotkeyDown()
    await eventually { cardStatuses(controller) == [.paused] }
    controller.hotkeyUp()
    await controller.settle()
    await eventually { cardStatuses(controller) == [.countingDown(2)] }
    #expect(Self.failed(controller))
    #expect(cardStatuses(controller) == [.countingDown(2)])
    clock.advance(by: .seconds(2))
    await eventually { cardStatuses(controller) == [.done] }
    #expect(runner.prompts == Self.sent)
  }

  @Test func nothingHeardResumesTheCountdown() async {
    let controller = await countedTo2(FakeGateway([Self.send]), voice: FakeVoice(transcript: "  "))

    await press(controller)
    controller.hotkeyUp()
    await controller.settle()
    await eventually { cardStatuses(controller) == [.countingDown(2)] }
    #expect(controller.notice?.hasPrefix("Didn't catch that") == true)
    #expect(cardStatuses(controller) == [.countingDown(2)])
    clock.advance(by: .seconds(2))
    await eventually { cardStatuses(controller) == [.done] }
    #expect(runner.prompts == Self.sent)
  }

  @Test func aShortcutWithTheKeyResumesTheCountdown() async {
    let controller = await countedTo2(FakeGateway([Self.send]))

    await press(controller)
    #expect(cardStatuses(controller) == [.paused])
    controller.hotkeyCancelled()
    await controller.settle()
    await eventually { cardStatuses(controller) == [.countingDown(2)] }
    #expect(cardStatuses(controller) == [.countingDown(2)])
    clock.advance(by: .seconds(2))
    await eventually { cardStatuses(controller) == [.done] }
    #expect(runner.prompts == Self.sent)
  }

  /// A press's resume reaches the session behind any call queued before it,
  /// so it can land after the next press has paused again. It mustn't lift
  /// that press's pause: only the new request's answer does.
  @Test func aResumeThatLandsAfterTheNextPressKeepsItPaused() async {
    let controller = await countedTo2(
      FakeGateway([Self.send, Fixtures.answer("It's still counting.")]), voice: FakeVoice(transcript: "is it going?"))

    await press(controller)
    // A shortcut resumes the countdown, and the key goes down again before
    // that resume has reached the session.
    controller.hotkeyCancelled()
    controller.hotkeyDown()
    await eventually { controller.isMicLive }
    try? await Task.sleep(for: .milliseconds(30))
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(cardStatuses(controller) == [.paused] && runner.prompts.isEmpty)

    controller.hotkeyUp()
    await controller.settle()
    await eventually { cardStatuses(controller) == [.countingDown(2)] }
    #expect(controller.exchanges.last?.answer == "It's still counting.")
    #expect(cardStatuses(controller) == [.countingDown(2)])
    clock.advance(by: .seconds(2))
    await eventually { cardStatuses(controller) == [.done] }
    #expect(runner.prompts == Self.sent)
  }

  /// Cutting in drops the request the pause was waiting on, but you're
  /// speaking again, so it stays paused until the new request is answered.
  @Test func cuttingInKeepsItPausedUntilTheNewRequestIsAnswered() async {
    let gateway = SlowScriptedGateway([Self.send, Fixtures.answer("dropped"), Fixtures.answer("It's still counting.")])
    let controller = controller(gateway, voice: FakeVoice(transcript: "is it going?"))
    controller.ask("tell demo to carry on")
    await controller.settle()

    await press(controller)
    controller.hotkeyUp()
    await eventually { controller.phase == .thinking }
    controller.hotkeyDown()
    await eventually { controller.isMicLive }
    // Long enough for the dropped request's late answer to come back.
    try? await Task.sleep(for: .milliseconds(150))
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(cardStatuses(controller) == [.paused] && runner.prompts.isEmpty)

    controller.hotkeyUp()
    await controller.settle()
    await eventually { cardStatuses(controller) == [.countingDown(3)] }
    #expect(controller.exchanges.last?.answer == "It's still counting.")
    #expect(cardStatuses(controller) == [.countingDown(3)])
    clock.advance(by: .seconds(3))
    await eventually { cardStatuses(controller) == [.done] }
    #expect(runner.prompts == Self.sent)
  }

  @Test func returnWhilePausedSendsAtOnce() async {
    let controller = await countedTo2(FakeGateway([Self.send, Fixtures.answer("Sent.")]))

    await press(controller)
    controller.confirmNewest()
    await eventually { cardStatuses(controller) == [.done] }
    #expect(runner.prompts == Self.sent)
    controller.hotkeyUp()
    await controller.settle()
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(cardStatuses(controller) == [.done] && runner.prompts == Self.sent)
  }

  @Test func cancelWhilePausedSendsNothing() async {
    let controller = await countedTo2(FakeGateway([Self.send, Fixtures.answer("Okay.")]))

    await press(controller)
    controller.cancel("a1")
    await eventually { cardStatuses(controller) == [.cancelled] }
    controller.hotkeyUp()
    await controller.settle()
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(cardStatuses(controller) == [.cancelled] && runner.prompts.isEmpty)
  }

  @Test func closingTheNoteWhilePausedDropsItUnsent() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("No, you closed the note.")])
    let controller = await countedTo2(gateway)

    await press(controller)
    controller.dismiss()
    await controller.settle()
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.prompts.isEmpty && clock.sleeping == 0)

    controller.ask("was it sent?")
    await controller.settle()
    let current = try #require(gateway.requests.last?.messages.last?.content)
    #expect(current.contains("a1 was cancelled during the countdown, when the user closed the note; nothing was done."))
  }
}
