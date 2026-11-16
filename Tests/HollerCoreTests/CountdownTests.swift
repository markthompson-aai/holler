import Foundation
import Testing

@testable import HollerCore

/// Simple actions run after a countdown instead of waiting on a card, once
/// the user has allowed that (ADR 0001): here a send to an idle agent, through
/// the session, on a clock the test moves. Everything else keeps its card.
@Suite struct CountdownTests {
  let runner = FakeRunner()
  let clock = TestClock()
  let events = Events()

  func session(_ gateway: any ChatCompleting, _ client: HerdrClient? = nil) -> AssistantSession {
    AssistantSession(
      gateway: gateway, herdr: client ?? Fixtures.client(runner), configuration: .init(model: "test-model", prefetchLines: 0),
      clock: clock)
  }

  static let send = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#)
  static let sent = [["agent", "prompt", "w1:p1", "carry on"]]

  /// Asks with the setting on, so a simple action counts down from 3.
  func askCountingDown(_ session: AssistantSession, _ request: String = "tell demo to carry on") async throws -> AssistantTurn {
    try await session.ask(request, countdown: .seconds(3)) { events.append($0) }
  }

  // MARK: - Counting down

  @Test func aSendToAnIdleAgentCountsDownThenSends() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("Yes, it went.")])
    let session = session(gateway)
    let turn = try await askCountingDown(session)
    #expect(turn.answer == "Sending to demo / main.")
    #expect(turn.actions.map(\.countdown) == [3])
    #expect(events.statuses(of: "a1").isEmpty && runner.writes.isEmpty)

    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .countingDown(2) }
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .countingDown(1) }
    #expect(runner.writes.isEmpty)
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .done }

    #expect(events.statuses(of: "a1") == [.countingDown(2), .countingDown(1), .busy, .done])
    #expect(runner.writes == Self.sent)
    _ = try await session.ask("did it go?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("a1's countdown ended; the message was sent to w1:p1."))
    #expect(!followUp.contains("The user confirmed"))
  }

  @Test func theModelIsToldItRunsIn3sUnlessCancelled() async throws {
    let gateway = FakeGateway([ActionStatusTests.withARead(Self.send), Fixtures.answer("Sending it.")])
    let turn = try await askCountingDown(session(gateway))
    #expect(turn.answer == "Sending it.")
    let result = try #require(gateway.requests.last?.messages.dropLast().last?.content)
    #expect(result == #"{"status":"runs_in_3s_unless_the_user_cancels","action_id":"a1"}"#)
  }

  @Test func withoutTheSettingASendWaits() async throws {
    let session = session(FakeGateway([Self.send]))
    let turn = try await session.ask("tell demo to carry on") { events.append($0) }
    #expect(turn.answer == "Ready to send to demo / main.")
    #expect(turn.actions.map(\.countdown) == [nil])

    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1").isEmpty && runner.writes.isEmpty)
    try await session.confirm("a1")
    #expect(runner.writes == Self.sent)
  }

  @Test func aSendToADoneAgentCountsDownThenSends() async throws {
    runner.snapshot = Fixtures.snapshot(demoAgent: "done")
    let turn = try await askCountingDown(session(FakeGateway([Self.send])))
    #expect(turn.actions.map(\.countdown) == [3])

    clock.advance(by: .seconds(3))
    await eventually { events.statuses(of: "a1").last == .done }
    #expect(events.statuses(of: "a1") == [.countingDown(2), .countingDown(1), .busy, .done])
    #expect(runner.writes == Self.sent)
  }

  @Test func aSendToAWorkingAgentWaits() async throws {
    runner.snapshot = InterruptAgentTests.snapshotWorking
    let gateway = FakeGateway([ActionStatusTests.withARead(Self.send), Fixtures.answer("Ready.")])
    let turn = try await askCountingDown(session(gateway))
    #expect(turn.actions.map(\.countdown) == [nil])
    let result = try #require(gateway.requests.last?.messages.dropLast().last?.content)
    #expect(result == #"{"status":"awaiting_user_confirmation","action_id":"a1"}"#)

    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1").isEmpty && runner.writes.isEmpty)
  }

  @Test func showMeFirstKeepsTheCard() async throws {
    let shown = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on","confirm":true}"#)
    let turn = try await askCountingDown(session(FakeGateway([shown])), "draft a message telling demo to carry on")
    #expect(turn.answer == "Ready to send to demo / main.")
    #expect(turn.actions.map(\.countdown) == [nil])

    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1").isEmpty && runner.writes.isEmpty)
  }

  @Test func promptAgentOffersConfirmWithoutRequiringIt() throws {
    let parameters = try #require(AssistantTools.named("prompt_agent")?.definition.function.parameters)
    #expect(parameters["properties"]?["confirm"]?["type"] == "boolean")
    guard case .array(let required) = parameters["required"] else {
      Issue.record("no required list")
      return
    }
    #expect(!required.contains("confirm"))
  }

  // MARK: - Stepping in

  @Test func confirmingDuringTheCountdownSendsAtOnce() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("Yes.")])
    let session = session(gateway)
    _ = try await askCountingDown(session)
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .countingDown(2) }

    try await session.confirm("a1") { events.append($0) }
    #expect(events.statuses(of: "a1") == [.countingDown(2), .busy, .done])
    #expect(runner.writes == Self.sent)

    // The countdown reaching the end runs nothing more.
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1") == [.countingDown(2), .busy, .done])
    #expect(runner.writes == Self.sent)
    _ = try await session.ask("did it go?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user confirmed a1; the message was sent to w1:p1."))
  }

  @Test func cancellingDuringTheCountdownSendsNothing() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("Okay.")])
    let session = session(gateway)
    _ = try await askCountingDown(session)

    await session.cancel("a1") { events.append($0) }
    #expect(events.statuses(of: "a1") == [.cancelled])
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1") == [.cancelled])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("never mind")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user cancelled a1 during its countdown; nothing was done."))
  }

  @Test func closingTheNoteDuringTheCountdownSendsNothing() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("No.")])
    let session = session(gateway)
    _ = try await askCountingDown(session)
    clock.advance(by: .seconds(2))
    await eventually { events.statuses(of: "a1").last == .countingDown(1) }

    await session.drop(["a1"])
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("was it sent?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("a1 was cancelled during the countdown, when the user closed the note; nothing was done."))
  }

  @Test func stoppingACountdownTakesEffectAheadOfTheDrop() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("No.")])
    let session = session(gateway)
    _ = try await askCountingDown(session)

    // The note closed: its countdown stops at once, before the drop that
    // follows has reached the session.
    session.stopCountdowns(["a1"])
    clock.advance(by: .seconds(3))
    await eventually { events.statuses(of: "a1").last == .withdrawn }
    #expect(events.statuses(of: "a1") == [.countingDown(2), .countingDown(1), .withdrawn])
    #expect(runner.writes.isEmpty)

    await session.drop(["a1"])
    _ = try await session.ask("was it sent?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.components(separatedBy: "a1 was cancelled during the countdown").count == 2)
  }

  // MARK: - The timer stops with the countdown

  /// A session with a1 counting down, once its timer is asleep on the clock.
  func counting() async throws -> AssistantSession {
    let session = session(FakeGateway([Self.send]))
    _ = try await askCountingDown(session)
    await eventually { clock.sleeping == 1 }
    #expect(clock.sleeping == 1)
    return session
  }

  @Test func cancellingTheLastCountingActionStopsTheTimer() async throws {
    let session = try await counting()
    await session.cancel("a1")
    await eventually { clock.sleeping == 0 }
    #expect(clock.sleeping == 0)
  }

  @Test func droppingTheLastCountingActionStopsTheTimer() async throws {
    let session = try await counting()
    await session.drop(["a1"])
    await eventually { clock.sleeping == 0 }
    #expect(clock.sleeping == 0)
  }

  @Test func confirmingTheLastCountingActionStopsTheTimer() async throws {
    let session = try await counting()
    try await session.confirm("a1")
    await eventually { clock.sleeping == 0 }
    #expect(clock.sleeping == 0)
  }

  @Test func aNewConversationEndsTheCountdown() async throws {
    let session = try await counting()
    await session.newConversation()
    await eventually { clock.sleeping == 0 }
    #expect(clock.sleeping == 0)
    #expect(events.statuses(of: "a1") == [.withdrawn])
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.writes.isEmpty)
  }

  @Test func aFailedRequestWithdrawsASendBeforeItCounts() async throws {
    let gateway = FakeGateway([ActionStatusTests.withARead(Self.send)], failing: [2])
    let session = session(gateway)
    await #expect(throws: FakeGateway.failure) { try await askCountingDown(session) }
    #expect(events.statuses(of: "a1") == [.withdrawn])

    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1") == [.withdrawn] && runner.writes.isEmpty)
  }

  // MARK: - The check at the end

  @Test func anAgentThatStartsWorkingDuringTheCountdownGetsACard() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("It waits for you.")])
    let session = session(gateway)
    _ = try await askCountingDown(session)
    runner.snapshot = InterruptAgentTests.snapshotWorking

    clock.advance(by: .seconds(3))
    let fellBack = ActionStatus.waiting(because: "main started working, so this waits for you.")
    await eventually { events.statuses(of: "a1").last == fellBack }
    #expect(events.statuses(of: "a1") == [.countingDown(2), .countingDown(1), fellBack])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("what happened?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(
      followUp.contains(
        "a1's countdown ended, but it no longer qualified to run without a card, so it waits for the user to confirm; "
          + "nothing was done. Its card tells the user: \"main started working, so this waits for you.\""))

    // The card now waits like any other: Return sends it, with the usual note.
    try await session.confirm("a1") { events.append($0) }
    #expect(events.statuses(of: "a1").suffix(2) == [.busy, .done])
    #expect(runner.writes == Self.sent)
  }

  @Test func anAgentThatGetsBlockedDuringTheCountdownGetsACard() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("It waits for you.")])
    let session = session(gateway)
    _ = try await askCountingDown(session)
    runner.snapshot = Fixtures.snapshot(demoAgent: "blocked")

    clock.advance(by: .seconds(3))
    let fellBack = ActionStatus.waiting(because: "main needs you, so this waits for you.")
    await eventually { events.statuses(of: "a1").last == fellBack }
    #expect(events.statuses(of: "a1").last == fellBack)
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("what happened?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("a1's countdown ended, but it no longer qualified to run without a card"))
  }

  @Test func herdrUnreadableAtTheEndGivesACardAndSaysSo() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("It waits for you.")])
    let session = session(gateway)
    _ = try await askCountingDown(session)
    runner.snapshot = "not a snapshot"

    clock.advance(by: .seconds(3))
    let fellBack = ActionStatus.waiting(because: "Herdr couldn't be checked, so this waits for you.")
    await eventually { events.statuses(of: "a1").last == fellBack }
    #expect(events.statuses(of: "a1").last == fellBack)
    #expect(runner.writes.isEmpty)
    runner.snapshot = Fixtures.snapshot
    _ = try await session.ask("what happened?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("a1's countdown ended, but Herdr couldn't be read to check it again"))
    #expect(!followUp.contains("no longer qualified"))
  }

  @Test func aSendThatFailsAfterTheCountdownShowsFailed() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("It didn't go.")])
    let session = session(gateway)
    _ = try await askCountingDown(session)
    runner.promptResult = Fixtures.herdrError("pane_not_found", "no such pane")

    clock.advance(by: .seconds(3))
    await eventually {
      if case .failed = events.statuses(of: "a1").last { true } else { false }
    }
    #expect(events.statuses(of: "a1").dropLast() == [.countingDown(2), .countingDown(1), .busy])
    guard case .failed(let reason) = events.statuses(of: "a1").last else {
      Issue.record("a1 didn't fail: \(events.statuses(of: "a1"))")
      return
    }
    #expect(!reason.isEmpty)
    _ = try await session.ask("did it go?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("a1's countdown ended but sending failed"))
  }

  @Test func anAgentThatGoesDuringTheCountdownGetsACard() async throws {
    let session = session(FakeGateway([Self.send]))
    _ = try await askCountingDown(session)
    runner.snapshot = Fixtures.snapshotWithoutDemoAgent

    clock.advance(by: .seconds(3))
    let fellBack = ActionStatus.waiting(because: "main is no longer open, so this waits for you.")
    await eventually { events.statuses(of: "a1").last == fellBack }
    #expect(events.statuses(of: "a1").last == fellBack)
    #expect(runner.writes.isEmpty)
  }

  /// Herdr restarted during the countdown, and w1:p1 is someone else's now.
  @Test func anAgentReplacedInItsPaneDuringTheCountdownGetsACardThatRefusesToSend() async throws {
    runner.snapshot = HerdrClientTests.snapshot(demoTerminal: "term_a")
    let gateway = FakeGateway([Self.send, Fixtures.answer("It didn't go.")])
    let session = session(gateway)
    _ = try await askCountingDown(session)
    runner.snapshot = HerdrClientTests.snapshot(demoTerminal: "term_b")

    clock.advance(by: .seconds(3))
    let fellBack = ActionStatus.waiting(because: "main is no longer in that pane, so this waits for you.")
    await eventually { events.statuses(of: "a1").last == fellBack }
    #expect(events.statuses(of: "a1").last == fellBack)
    #expect(runner.writes.isEmpty)

    await #expect(throws: HerdrError.agentChanged("w1:p1")) { try await session.confirm("a1") { events.append($0) } }
    #expect(
      events.statuses(of: "a1").last
        == .failed("w1:p1 no longer holds the agent on the card, so Holler left it alone; ask again"))
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("did it go?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user confirmed a1 but sending failed: w1:p1 no longer holds the agent on the card"))
  }

  // MARK: - Several at once

  @Test func twoSendsFromOneRequestShareOneCountdownEachCancellable() async throws {
    let gateway = FakeGateway([
      ChatMessage(
        role: .assistant, content: nil,
        toolCalls: [
          ToolCall(id: "c1", name: "prompt_agent", arguments: #"{"pane_id":"w1:p1","message":"carry on"}"#),
          ToolCall(id: "c2", name: "prompt_agent", arguments: #"{"pane_id":"w1:p1","message":"then run the tests"}"#),
        ])
    ])
    let session = session(gateway)
    let turn = try await askCountingDown(session)
    #expect(turn.answer == "Sending to demo / main. Sending to demo / main.")
    #expect(turn.actions.map(\.countdown) == [3, 3])

    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a2").last == .countingDown(2) }
    #expect(events.statuses(of: "a1") == [.countingDown(2)])
    await session.cancel("a1") { events.append($0) }

    clock.advance(by: .seconds(2))
    await eventually { events.statuses(of: "a2").last == .done }
    #expect(events.statuses(of: "a1") == [.countingDown(2), .cancelled])
    #expect(events.statuses(of: "a2") == [.countingDown(2), .countingDown(1), .busy, .done])
    #expect(runner.writes == [["agent", "prompt", "w1:p1", "then run the tests"]])
  }

  @Test func aLaterRequestsSendCountsFrom3WhileTheFirstCarriesOn() async throws {
    let later = Fixtures.toolCall("c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"then run the tests"}"#)
    let session = session(FakeGateway([Self.send, later]))
    _ = try await askCountingDown(session)
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .countingDown(2) }

    let turn = try await askCountingDown(session, "and tell it to run the tests")
    #expect(turn.actions.map(\.countdown) == [3])
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .countingDown(1) && events.statuses(of: "a2").last == .countingDown(2) }
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .done && events.statuses(of: "a2").last == .countingDown(1) }
    #expect(runner.writes == Self.sent)
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a2").last == .done }

    #expect(events.statuses(of: "a1") == [.countingDown(2), .countingDown(1), .busy, .done])
    #expect(events.statuses(of: "a2") == [.countingDown(2), .countingDown(1), .busy, .done])
    #expect(runner.writes == Self.sent + [["agent", "prompt", "w1:p1", "then run the tests"]])
  }

  @Test func aCorrectionDuringTheCountdownReplacesTheCountingCard() async throws {
    let gateway = FakeGateway([
      Self.send, Fixtures.toolCall("c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"stop instead","replaces":"a1"}"#),
    ])
    let session = session(gateway)
    _ = try await askCountingDown(session)
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .countingDown(2) }

    let turn = try await askCountingDown(session, "actually, tell it to stop instead")
    #expect(turn.actions.map(\.id) == ["a2"] && turn.replaced == ["a1"])
    #expect(events.statuses(of: "a1") == [.countingDown(2), .replaced])

    clock.advance(by: .seconds(3))
    await eventually { events.statuses(of: "a2").last == .done }
    #expect(runner.writes == [["agent", "prompt", "w1:p1", "stop instead"]])
    #expect(events.statuses(of: "a1") == [.countingDown(2), .replaced])
  }

  // MARK: - Paused while the user speaks

  /// A session with a1 counting down from 3, ticked down to 2.
  func countedTo2(_ gateway: any ChatCompleting) async throws -> AssistantSession {
    let session = session(gateway)
    _ = try await askCountingDown(session)
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .countingDown(2) }
    return session
  }

  @Test func pausingHoldsTheCountdownWhereItStoodUntilItResumes() async throws {
    let session = try await countedTo2(FakeGateway([Self.send]))

    let pause = session.pauseCountdowns()
    await eventually { events.statuses(of: "a1").last == .paused }
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused])
    await eventually { clock.sleeping == 0 }
    #expect(clock.sleeping == 0)
    // Time passing during the pause doesn't move it.
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused] && runner.writes.isEmpty)

    await session.resumeCountdowns(pause)
    #expect(events.statuses(of: "a1").last == .countingDown(2))
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .countingDown(1) }
    #expect(runner.writes.isEmpty)
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .done }
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused, .countingDown(2), .countingDown(1), .busy, .done])
    #expect(runner.writes == Self.sent)
  }

  @Test func aPauseTakesEffectEvenIfTheCountdownWouldEndFirst() async throws {
    let session = try await countedTo2(FakeGateway([Self.send]))
    // The countdown's end is due before the session has had a chance to
    // pause anything: it holds anyway.
    let pause = session.pauseCountdowns()
    clock.advance(by: .seconds(5))
    await eventually { events.statuses(of: "a1").last == .paused }
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1").last == .paused && runner.writes.isEmpty)

    await session.resumeCountdowns(pause)
    clock.advance(by: .seconds(5))
    await eventually { events.statuses(of: "a1").last == .done }
    #expect(runner.writes == Self.sent)
  }

  @Test func pausingStopsEveryCountdownAtOnce() async throws {
    let later = Fixtures.toolCall("c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"then run the tests"}"#)
    let session = try await countedTo2(FakeGateway([Self.send, later]))
    _ = try await askCountingDown(session, "and tell it to run the tests")

    let pause = session.pauseCountdowns()
    await eventually { events.statuses(of: "a1").last == .paused && events.statuses(of: "a2").last == .paused }
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused])
    #expect(events.statuses(of: "a2") == [.paused])
    #expect(runner.writes.isEmpty)

    await session.resumeCountdowns(pause)
    #expect(events.statuses(of: "a1").last == .countingDown(2) && events.statuses(of: "a2").last == .countingDown(3))
  }

  @Test func aCorrectionWhilePausedDropsTheOldActionAndTheNewOneCountsFrom3() async throws {
    let correction = Fixtures.toolCall(
      "c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"stop instead","replaces":"a1"}"#)
    let gateway = FakeGateway([Self.send, correction, Fixtures.answer("Sent.")])
    let session = try await countedTo2(gateway)
    let pause = session.pauseCountdowns()
    await eventually { events.statuses(of: "a1").last == .paused }

    let turn = try await askCountingDown(session, "actually, tell it to stop instead")
    await session.resumeCountdowns(pause)
    #expect(turn.replaced == ["a1"] && turn.actions.map(\.countdown) == [3])
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused, .replaced])

    clock.advance(by: .seconds(2))
    await eventually { events.statuses(of: "a2").last == .countingDown(1) }
    #expect(runner.writes.isEmpty)
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a2").last == .done }
    #expect(runner.writes == [["agent", "prompt", "w1:p1", "stop instead"]])
    #expect(events.statuses(of: "a1").last == .replaced)
    _ = try await session.ask("did it go?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("a1 was dropped because a2 replaced it as a correction; nothing was done."))
  }

  @Test func anAdditionWhilePausedResumesTheFirstAndCountsDownTheSecond() async throws {
    let addition = Fixtures.toolCall("c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"and run the tests"}"#)
    let session = try await countedTo2(FakeGateway([Self.send, addition]))
    let pause = session.pauseCountdowns()
    await eventually { events.statuses(of: "a1").last == .paused }

    let turn = try await askCountingDown(session, "and also tell it to run the tests")
    await session.resumeCountdowns(pause)
    #expect(turn.replaced.isEmpty && turn.actions.map(\.countdown) == [3])
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused, .countingDown(2)])

    clock.advance(by: .seconds(2))
    await eventually { events.statuses(of: "a1").last == .done && events.statuses(of: "a2").last == .countingDown(1) }
    #expect(runner.writes == Self.sent)
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a2").last == .done }
    #expect(runner.writes == Self.sent + [["agent", "prompt", "w1:p1", "and run the tests"]])
  }

  @Test func cancellingAPausedCardSendsNothingAndStopsItsCountdown() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("Okay.")])
    let session = try await countedTo2(gateway)
    let pause = session.pauseCountdowns()
    await eventually { events.statuses(of: "a1").last == .paused }

    await session.cancel("a1") { events.append($0) }
    await session.resumeCountdowns(pause)
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused, .cancelled])
    #expect(runner.writes.isEmpty && clock.sleeping == 0)
    _ = try await session.ask("never mind")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user cancelled a1 during its countdown; nothing was done."))
  }

  @Test func confirmingAPausedCardSendsAtOnce() async throws {
    let session = try await countedTo2(FakeGateway([Self.send]))
    let pause = session.pauseCountdowns()
    await eventually { events.statuses(of: "a1").last == .paused }

    try await session.confirm("a1") { events.append($0) }
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused, .busy, .done])
    #expect(runner.writes == Self.sent)
    await session.resumeCountdowns(pause)
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.writes == Self.sent && clock.sleeping == 0)
  }

  @Test func closingTheNoteWhilePausedDropsItUnsent() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("No.")])
    let session = try await countedTo2(gateway)
    let pause = session.pauseCountdowns()
    await eventually { events.statuses(of: "a1").last == .paused }

    session.stopCountdowns(["a1"])
    await session.drop(["a1"])
    await session.resumeCountdowns(pause)
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.writes.isEmpty && clock.sleeping == 0)
    _ = try await session.ask("was it sent?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("a1 was cancelled during the countdown, when the user closed the note; nothing was done."))
  }

  @Test func aNewConversationWhilePausedDropsIt() async throws {
    let session = try await countedTo2(FakeGateway([Self.send]))
    let pause = session.pauseCountdowns()
    await eventually { events.statuses(of: "a1").last == .paused }

    await session.newConversation()
    await session.resumeCountdowns(pause)
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused, .withdrawn])
    #expect(runner.writes.isEmpty)
  }

  @Test func resumingAPauseAgainChangesNothing() async throws {
    let session = try await countedTo2(FakeGateway([Self.send]))
    let pause = session.pauseCountdowns()
    await eventually { events.statuses(of: "a1").last == .paused }
    await session.resumeCountdowns(pause)
    await session.resumeCountdowns(pause)
    clock.advance(by: .seconds(2))
    await eventually { events.statuses(of: "a1").last == .done }
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused, .countingDown(2), .countingDown(1), .busy, .done])
  }

  /// An earlier press's resume can reach the session after the next press
  /// has paused again: it leaves that pause holding, for the next press's
  /// own resume to lift.
  @Test func anEarlierPressesResumeLeavesALaterPressesPauseHolding() async throws {
    let session = try await countedTo2(FakeGateway([Self.send]))
    let first = session.pauseCountdowns()
    let second = session.pauseCountdowns()
    await session.resumeCountdowns(first)
    await eventually { events.statuses(of: "a1").last == .paused }
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused] && runner.writes.isEmpty)

    await session.resumeCountdowns(second)
    clock.advance(by: .seconds(2))
    await eventually { events.statuses(of: "a1").last == .done }
    #expect(events.statuses(of: "a1") == [.countingDown(2), .paused, .countingDown(2), .countingDown(1), .busy, .done])
    #expect(runner.writes == Self.sent)
  }

  // MARK: - Starts

  static func start(_ arguments: String) -> ChatMessage {
    Fixtures.toolCall("c1", "start_agent", arguments)
  }

  /// What a start in the demo workspace runs, from `ActionStatusTests.start(in:)`.
  static func started(_ folder: URL) -> [[String]] {
    [
      ["tab", "create", "--workspace", "w1", "--cwd", folder.path, "--label", "tests", "--no-focus"],
      ["agent", "start", "tests", "--kind", "claude", "--pane", "w1:p9", "--timeout", "30000"],
      ["agent", "prompt", "w1:p9", "Run the tests."],
    ]
  }

  @Test func aStartInANewTabCountsDownThenStarts() async throws {
    let folder = try Fixtures.folder()
    let gateway = FakeGateway([ActionStatusTests.start(in: folder), Fixtures.answer("It's running.")])
    let session = session(gateway)
    let turn = try await askCountingDown(session, "start an agent to run the tests")
    #expect(turn.answer == "Starting Claude in demo / tests.")
    #expect(turn.actions.map(\.countdown) == [3])
    #expect(turn.actions.map(\.waitsBecause) == [nil])

    clock.advance(by: .seconds(2))
    await eventually { events.statuses(of: "a1").last == .countingDown(1) }
    #expect(runner.writes.isEmpty)
    clock.advance(by: .seconds(1))
    await eventually { events.statuses(of: "a1").last == .done }

    #expect(events.statuses(of: "a1") == [.countingDown(2), .countingDown(1), .busy, .done])
    #expect(runner.writes == Self.started(folder))
    _ = try await session.ask("is it going?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("a1's countdown ended; a new Claude agent started in w1:p9 (demo / tests) and was given its task."))
  }

  @Test func theModelIsToldAStartRunsIn3sUnlessCancelled() async throws {
    let folder = try Fixtures.folder()
    let gateway = FakeGateway([ActionStatusTests.withARead(ActionStatusTests.start(in: folder)), Fixtures.answer("Starting it.")])
    _ = try await askCountingDown(session(gateway), "start an agent to run the tests")
    let result = try #require(gateway.requests.last?.messages.dropLast().last?.content)
    #expect(result == #"{"status":"runs_in_3s_unless_the_user_cancels","action_id":"a1"}"#)
  }

  @Test func aCodexStartWithNoTaskCountsDownThenStarts() async throws {
    let folder = try Fixtures.folder()
    let start = Self.start(#"{"agent":"codex","workspace":"demo","folder":"\#(folder.path)","tab_name":"web"}"#)
    let gateway = FakeGateway([start, Fixtures.answer("It's waiting.")])
    let session = session(gateway)
    let turn = try await askCountingDown(session, "start a codex agent")
    #expect(turn.answer == "Starting Codex in demo / web.")
    #expect(turn.actions.map(\.countdown) == [3])

    clock.advance(by: .seconds(3))
    await eventually { events.statuses(of: "a1").last == .done }
    #expect(runner.calls.contains(["agent", "start", "web", "--kind", "codex", "--pane", "w1:p9", "--timeout", "30000"]))
    #expect(runner.prompts.isEmpty)
    _ = try await session.ask("is it up?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("a1's countdown ended; a new Codex agent started in w1:p9 (demo / web) with no task yet."))
  }

  @Test func cancellingAStartDuringTheCountdownStartsNothing() async throws {
    let folder = try Fixtures.folder()
    let gateway = FakeGateway([ActionStatusTests.start(in: folder), Fixtures.answer("Okay.")])
    let session = session(gateway)
    _ = try await askCountingDown(session, "start an agent to run the tests")

    await session.cancel("a1") { events.append($0) }
    clock.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(events.statuses(of: "a1") == [.cancelled])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("never mind")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user cancelled a1 during its countdown; nothing was done."))
  }

  @Test func aStartStoppedByTheTrustQuestionAfterItsCountdownSaysSo() async throws {
    let folder = try Fixtures.folder()
    runner.agentStartResults = [Fixtures.herdrError("agent_not_ready")]
    let gateway = FakeGateway([ActionStatusTests.start(in: folder), Fixtures.answer("Answer it in the tab.")])
    let session = session(gateway)
    _ = try await askCountingDown(session, "start an agent to run the tests")

    clock.advance(by: .seconds(3))
    await eventually {
      if case .failed = events.statuses(of: "a1").last { true } else { false }
    }
    #expect(
      events.statuses(of: "a1") == [
        .countingDown(2), .countingDown(1), .busy,
        .failed(
          "The agent opened in w1:p9 but is waiting for you there, usually to ask whether to trust the folder. "
            + "Answer it in that tab; nothing else was sent"),
      ])
    #expect(runner.prompts.isEmpty)
    #expect(!runner.calls.contains { $0.starts(with: ["tab", "close"]) })
    _ = try await session.ask("what happened?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(
      followUp.contains(
        "a1's countdown ended; Claude opened in w1:p9 (demo / tests) but stopped at a question in its terminal, usually "
          + "whether to trust the folder. Its task was not sent."))
  }

  @Test func aStartWhoseWorkspaceClosesDuringTheCountdownGetsACard() async throws {
    let folder = try Fixtures.folder()
    let gateway = FakeGateway([ActionStatusTests.start(in: folder), Fixtures.answer("It waits for you.")])
    let session = session(gateway)
    _ = try await askCountingDown(session, "start an agent to run the tests")
    runner.snapshot = Self.snapshotWithoutDemo

    clock.advance(by: .seconds(3))
    let fellBack = ActionStatus.waiting(because: "Holler can no longer see the demo workspace, so this waits for you.")
    await eventually { events.statuses(of: "a1").last == fellBack }
    #expect(events.statuses(of: "a1") == [.countingDown(2), .countingDown(1), fellBack])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("what happened?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("a1's countdown ended, but it no longer qualified to run without a card"))
  }

  @Test func aStartTheWorkspaceFilterNowHidesGetsACard() async throws {
    let folder = try Fixtures.folder()
    let session = session(FakeGateway([ActionStatusTests.start(in: folder)]), Fixtures.client(runner, workspaces: ["demo"]))
    _ = try await askCountingDown(session, "start an agent to run the tests")
    // The demo workspace is renamed, out of the filter's reach.
    runner.snapshot = Fixtures.snapshot.replacingOccurrences(
      of: #"{"workspace_id":"w1","label":"demo"}"#, with: #"{"workspace_id":"w1","label":"elsewhere"}"#)

    clock.advance(by: .seconds(3))
    let fellBack = ActionStatus.waiting(because: "Holler can no longer see the demo workspace, so this waits for you.")
    await eventually { events.statuses(of: "a1").last == fellBack }
    #expect(events.statuses(of: "a1").last == fellBack)
    #expect(runner.writes.isEmpty)
  }

  /// The fixture snapshot after the demo workspace (w1) has closed, its tabs
  /// and agent with it.
  static let snapshotWithoutDemo = """
    {"id":"cli:api:snapshot","result":{"type":"snapshot","snapshot":{
      "protocol":22,"version":"0.9.3","focused_pane_id":"w2:p1",
      "agents":[
        {"agent":"codex","agent_status":"blocked","cwd":"/Users/test/Clients/acme","focused":true,
         "pane_id":"w2:p1","tab_id":"w2:t3","workspace_id":"w2","terminal_title_stripped":"Fix flaky test"}
      ],
      "tabs":[{"tab_id":"w2:t3","workspace_id":"w2","label":"tests"}],
      "workspaces":[{"workspace_id":"w2","label":"acme"}],
      "panes":[{"pane_id":"w2:p1","workspace_id":"w2","cwd":"/Users/test/Clients/acme"}],
      "layouts":[]
    }}}
    """

  @Test func startAgentOffersConfirmWithoutRequiringIt() throws {
    let parameters = try #require(AssistantTools.named("start_agent")?.definition.function.parameters)
    #expect(parameters["properties"]?["confirm"]?["type"] == "boolean")
    guard case .array(let required) = parameters["required"] else {
      Issue.record("no required list")
      return
    }
    #expect(!required.contains("confirm"))
  }

  @Test func showMeFirstKeepsAStartsCard() async throws {
    let folder = try Fixtures.folder()
    let start = Self.start(
      #"{"workspace":"demo","folder":"\#(folder.path)","tab_name":"tests","task":"Run the tests.","confirm":true}"#)
    let turn = try await askCountingDown(session(FakeGateway([start])), "show me the start first")
    #expect(turn.answer == "Ready to start Claude in demo / tests.")
    #expect(turn.actions.map(\.countdown) == [nil])
    #expect(turn.actions.map(\.waitsBecause) == ["You asked to see this first."])
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.writes.isEmpty)
  }

  @Test func aWorktreeStartWaitsAndSaysWhy() async throws {
    let folder = try Fixtures.folder()
    let client = Fixtures.client(runner, worktrees: try Fixtures.folder("worktrees").path)
    let start = Self.start(
      #"{"workspace":"demo","folder":"\#(folder.path)","tab_name":"cache-fix","task":"Try the fix.","worktree":true}"#)
    let gateway = FakeGateway([ActionStatusTests.withARead(start), Fixtures.answer("It waits for you.")])
    let turn = try await askCountingDown(session(gateway, client), "start claude in a worktree to try the fix")
    #expect(turn.actions.map(\.countdown) == [nil])
    #expect(turn.actions.map(\.waitsBecause) == ["Worktree starts wait for you."])
    let result = try #require(gateway.requests.last?.messages.dropLast().last?.content)
    #expect(result == #"{"status":"awaiting_user_confirmation","action_id":"a1"}"#)
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.writes.isEmpty)
  }

  // MARK: - Text an agent would run rather than read

  @Test(arguments: [
    ("!rm -rf build", "It starts with !, so this waits for you.", "Starts with !, so the agent runs it as a shell command rather than reading it."),
    ("  /compact", "It starts with /, so this waits for you.", "Starts with /, so the agent may run it as a slash command rather than read it."),
  ])
  func aSendTheAgentWouldRunWaitsAndItsCardWarns(message: String, why: String, warning: String) async throws {
    let send = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"\#(message)"}"#)
    let gateway = FakeGateway([ActionStatusTests.withARead(send), Fixtures.answer("It waits for you.")])
    let session = session(gateway)
    let turn = try await askCountingDown(session, "tell demo to run that")
    #expect(turn.actions.map(\.countdown) == [nil])
    #expect(turn.actions.map(\.waitsBecause) == [why])
    #expect(turn.actions.map(\.card.warnings) == [[warning]])
    let result = try #require(gateway.requests.last?.messages.dropLast().last?.content)
    #expect(result == #"{"status":"awaiting_user_confirmation","action_id":"a1"}"#)
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.writes.isEmpty)

    // It still goes, as written, once the user has read the card and confirmed.
    try await session.confirm("a1")
    #expect(runner.prompts == [["agent", "prompt", "w1:p1", message.trimmingCharacters(in: .whitespaces)]])
  }

  @Test func withTheSettingOffItsCardStillWarns() async throws {
    let send = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"!make deploy"}"#)
    let turn = try await session(FakeGateway([send])).ask("tell demo to deploy")
    #expect(turn.actions.map(\.waitsBecause) == [nil])
    #expect(turn.actions.map(\.card.warnings) == [["Starts with !, so the agent runs it as a shell command rather than reading it."]])
  }

  @Test func anOrdinaryMessageCarriesNoWarning() async throws {
    for message in ["carry on", "run make! then stop", "fix src/a.swift", "is 1/2 right?"] {
      let send = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"\#(message)"}"#)
      let turn = try await askCountingDown(session(FakeGateway([send])))
      #expect(turn.actions.map(\.countdown) == [3])
      #expect(turn.actions.map(\.card.warnings) == [[]])
    }
  }

  @Test func aStartWhoseTaskTheAgentWouldRunWaitsAndItsCardWarns() async throws {
    let folder = try Fixtures.folder()
    let start = Self.start(#"{"workspace":"demo","folder":"\#(folder.path)","tab_name":"tests","task":"!./run_tests.sh"}"#)
    let turn = try await askCountingDown(session(FakeGateway([start])), "start an agent to run the tests")
    #expect(turn.answer == "Ready to start Claude in demo / tests.")
    #expect(turn.actions.map(\.countdown) == [nil])
    #expect(turn.actions.map(\.waitsBecause) == ["It starts with !, so this waits for you."])
    #expect(turn.actions.map(\.card.warnings) == [["Starts with !, so the agent runs it as a shell command rather than reading it."]])
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.writes.isEmpty)
  }

  @Test func theToolsSayWhatALeadingBangOrSlashDoes() throws {
    for tool in ["prompt_agent", "start_agent"] {
      let definition = try #require(AssistantTools.named(tool)?.definition)
      let schema = String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)
      #expect(schema.contains("Never start it with ! or \\/ unless the user asked for exactly that shell command"))
    }
  }

  // MARK: - Why a card waits

  @Test func aSendToAWorkingAgentSaysWhyItWaits() async throws {
    runner.snapshot = InterruptAgentTests.snapshotWorking
    let turn = try await askCountingDown(session(FakeGateway([Self.send])))
    #expect(turn.actions.map(\.waitsBecause) == ["main is working, so this waits for you."])
  }

  @Test func showMeFirstOnASendSaysWhyItWaits() async throws {
    let shown = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on","confirm":true}"#)
    let turn = try await askCountingDown(session(FakeGateway([shown])), "show me the message first")
    #expect(turn.actions.map(\.waitsBecause) == ["You asked to see this first."])
  }

  @Test func withTheSettingOffNoCardSaysWhy() async throws {
    runner.snapshot = InterruptAgentTests.snapshotWorking
    let shown = Fixtures.toolCall("c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on","confirm":true}"#)
    let session = session(FakeGateway([Self.send, shown]))
    let working = try await session.ask("tell demo to carry on")
    let firstShown = try await session.ask("show me a message to demo first")
    #expect(working.actions.map(\.waitsBecause) == [nil] && firstShown.actions.map(\.waitsBecause) == [nil])
  }

  @Test func closeAndInterruptCardsNeverSayWhy() async throws {
    let (closeRunner, closeClient) = CloseTabTests.started()
    let close = try await askCountingDown(session(FakeGateway([ActionStatusTests.close]), closeClient), "close it")
    let (_, interruptClient) = InterruptAgentTests.working()
    let interrupt = Fixtures.toolCall("c1", "interrupt_agent", #"{"pane_id":"w1:p1"}"#)
    let stop = try await askCountingDown(session(FakeGateway([interrupt]), interruptClient), "stop the demo agent")
    #expect(close.actions.map(\.waitsBecause) == [nil] && stop.actions.map(\.waitsBecause) == [nil])
    #expect(closeRunner.writes.isEmpty)
  }

  // MARK: - Everything else keeps its card

  @Test func aCloseStillWaits() async throws {
    let (runner, client) = CloseTabTests.started()
    let session = session(FakeGateway([ActionStatusTests.close]), client)
    let turn = try await askCountingDown(session, "close the dark-mode tab")
    #expect(turn.answer == "Ready to close demo / dark-mode.")
    #expect(turn.actions.map(\.countdown) == [nil])
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.writes.isEmpty)
  }

  @Test func anInterruptStillWaits() async throws {
    let (runner, client) = InterruptAgentTests.working()
    let interrupt = Fixtures.toolCall("c1", "interrupt_agent", #"{"pane_id":"w1:p1"}"#)
    let session = session(FakeGateway([interrupt]), client)
    let turn = try await askCountingDown(session, "stop the demo agent")
    #expect(turn.answer == "Ready to interrupt demo / main.")
    #expect(turn.actions.map(\.countdown) == [nil])
    clock.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(runner.writes.isEmpty)
  }
}
