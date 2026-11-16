import Foundation
import Testing

@testable import HollerCore

/// Interrupting a working agent with Esc: which agents can be, the re-check on
/// confirm, and the action through the session. No agent here is in a tab
/// Holler started.
@Suite struct InterruptAgentTests {
  /// The fixture snapshot with the demo agent (w1:p1) working.
  static let snapshotWorking = Fixtures.snapshot.replacingOccurrences(
    of: #""agent_status":"idle","cwd":"/Users/test/Projects/demo""#,
    with: #""agent_status":"working","cwd":"/Users/test/Projects/demo""#)

  static func working(excluding: [String] = [], workspaces: [String] = []) -> (FakeRunner, HerdrClient) {
    let runner = FakeRunner(snapshot: snapshotWorking, readOutput: "⏺ Rewriting the parser.\n\n❯ \n⏵⏵ auto mode on\n")
    return (runner, Fixtures.client(runner, excluding: excluding, workspaces: workspaces))
  }

  static let esc = [["agent", "send-keys", "w1:p1", "esc"]]

  // MARK: - Checking a request

  @Test func checkDescribesTheAgentWithoutSendingAnything() async throws {
    let (runner, client) = Self.working()
    let target = try await client.checkInterrupt(paneId: "w1:p1")
    #expect(target.agent.paneId == "w1:p1" && target.agent.status == "working")
    #expect(target.lastLine == "Rewriting the parser.")
    #expect(runner.writes.isEmpty)
  }

  @Test func anIdleAgentIsRefused() async throws {
    let runner = FakeRunner()
    await #expect(throws: HerdrError.notWorking(paneId: "w1:p1", status: "idle")) {
      try await Fixtures.client(runner).checkInterrupt(paneId: "w1:p1")
    }
    #expect(runner.writes.isEmpty)
  }

  @Test func aBlockedAgentIsRefusedSoEscNeverAnswersItsPrompt() async throws {
    let (runner, client) = Self.working()
    await #expect(throws: HerdrError.notWorking(paneId: "w2:p1", status: "blocked")) {
      try await client.checkInterrupt(paneId: "w2:p1")
    }
    #expect(
      HerdrError.notWorking(paneId: "w2:p1", status: "blocked").description
        == "the agent in w2:p1 is waiting on you in its terminal, so Holler won't interrupt it; answer it there")
    #expect(runner.writes.isEmpty)
  }

  @Test func aHiddenOrUnknownPaneIsRefused() async throws {
    let (runner, inAcmeOnly) = Self.working(workspaces: ["acme"])
    await #expect(throws: HerdrError.unknownPane("w1:p1")) { try await inAcmeOnly.checkInterrupt(paneId: "w1:p1") }
    await #expect(throws: HerdrError.unknownPane("w9:p9")) { try await inAcmeOnly.checkInterrupt(paneId: "w9:p9") }
    let excluded = Fixtures.client(runner, excluding: ["/Users/test/Projects"])
    await #expect(throws: HerdrError.unknownPane("w1:p1")) { try await excluded.checkInterrupt(paneId: "w1:p1") }
    #expect(runner.writes.isEmpty)
  }

  // MARK: - Interrupting

  @Test func anAgentHollerDidNotStartGetsEsc() async throws {
    let (runner, client) = Self.working()
    #expect(try await client.state().startedTabs.isEmpty)
    let agent = try await client.interrupt(try await client.checkInterrupt(paneId: "w1:p1"))
    #expect(agent.paneId == "w1:p1")
    #expect(runner.writes == Self.esc)
  }

  @Test func interruptChecksAgainSoAnAgentThatFinishedIsLeftAlone() async throws {
    let (runner, client) = Self.working()
    let target = try await client.checkInterrupt(paneId: "w1:p1")
    runner.snapshot = Fixtures.snapshot
    await #expect(throws: HerdrError.notWorking(paneId: "w1:p1", status: "idle")) { try await client.interrupt(target) }
    runner.snapshot = Self.snapshotWorking.replacingOccurrences(
      of: #""agent_status":"working","cwd":"/Users/test/Projects/demo""#,
      with: #""agent_status":"blocked","cwd":"/Users/test/Projects/demo""#)
    await #expect(throws: HerdrError.notWorking(paneId: "w1:p1", status: "blocked")) { try await client.interrupt(target) }
    #expect(runner.writes.isEmpty)
  }

  @Test func interruptChecksAgainSoAGoneOrNowHiddenAgentIsLeftAlone() async throws {
    let (runner, client) = Self.working(excluding: ["/Users/test/Clients"])
    let target = try await client.checkInterrupt(paneId: "w1:p1")
    runner.snapshot = Self.snapshotWorking.replacingOccurrences(of: #""pane_id":"w1:p1","tab_id""#, with: #""pane_id":"w1:p7","tab_id""#)
    await #expect(throws: HerdrError.unknownPane("w1:p1")) { try await client.interrupt(target) }
    runner.snapshot = Self.snapshotWorking.replacingOccurrences(
      of: #""cwd":"/Users/test/Projects/demo","focused":false"#, with: #""cwd":"/Users/test/Clients/acme","focused":false"#)
    await #expect(throws: HerdrError.unknownPane("w1:p1")) { try await client.interrupt(target) }
    #expect(runner.writes.isEmpty)
  }

  /// After Herdr restarts, w1:p1 can be another agent: here a Codex in another tab.
  @Test func interruptChecksAgainSoADifferentAgentInThePaneIsLeftAlone() async throws {
    let (runner, client) = Self.working()
    let target = try await client.checkInterrupt(paneId: "w1:p1")
    runner.snapshot = Self.snapshotWorking.replacingOccurrences(
      of: #"{"agent":"claude","agent_status":"working""#, with: #"{"agent":"codex","agent_status":"working""#)
    await #expect(throws: HerdrError.agentChanged("w1:p1")) { try await client.interrupt(target) }
    runner.snapshot = Self.snapshotWorking.replacingOccurrences(
      of: #""pane_id":"w1:p1","tab_id":"w1:t1""#, with: #""pane_id":"w1:p1","tab_id":"w1:t2""#)
    await #expect(throws: HerdrError.agentChanged("w1:p1")) { try await client.interrupt(target) }
    #expect(runner.writes.isEmpty)
  }

  /// The same pane and tab ids, and another Claude working there, but on
  /// another terminal: the agent on the card has gone.
  @Test func interruptChecksAgainSoAnotherTerminalInThePaneIsLeftAlone() async throws {
    func working(on terminal: String) -> String {
      Self.snapshotWorking.replacingOccurrences(
        of: #""pane_id":"w1:p1","tab_id":"w1:t1""#, with: #""pane_id":"w1:p1","tab_id":"w1:t1","terminal_id":"\#(terminal)""#)
    }
    let (runner, client) = Self.working()
    runner.snapshot = working(on: "term_a")
    let target = try await client.checkInterrupt(paneId: "w1:p1")

    runner.snapshot = working(on: "term_b")
    await #expect(throws: HerdrError.agentChanged("w1:p1")) { try await client.interrupt(target) }
    runner.snapshot = working(on: "term_a").replacingOccurrences(
      of: #"{"tab_id":"w1:t1","workspace_id":"w1","label":"main"}"#, with: #"{"tab_id":"w1:t1","workspace_id":"w1","label":"billing"}"#)
    await #expect(throws: HerdrError.agentChanged("w1:p1")) { try await client.interrupt(target) }
    #expect(runner.writes.isEmpty)

    runner.snapshot = working(on: "term_a")
    try await client.interrupt(target)
    #expect(runner.writes == Self.esc)
  }

  // MARK: - Through the session

  func session(_ gateway: FakeGateway, _ client: HerdrClient) -> AssistantSession {
    AssistantSession(gateway: gateway, herdr: client, configuration: .init(model: "test-model", prefetchLines: 0))
  }

  static let interrupt = Fixtures.toolCall("c1", "interrupt_agent", #"{"pane_id":"w1:p1"}"#)

  @Test func aQueuedInterruptCarriesItsCard() async throws {
    let (runner, client) = Self.working()
    let events = Events()
    let turn = try await session(FakeGateway([Self.interrupt]), client).ask("stop the demo agent") { events.append($0) }

    #expect(turn.answer == "Ready to interrupt demo / main.")
    #expect(
      events.queued.map(\.card) == [
        ConfirmCard(
          kind: .interrupt, verb: "Interrupt", target: "demo / main",
          placeholder: "It stops what it's doing and waits at its prompt. The tab stays open.",
          details: [.init(label: "Claude · working", text: "Rewriting the parser.", placeholder: "No output yet.")],
          words: .init(
            button: "Interrupt", busy: "Interrupting…", done: "Interrupted", cancelled: "Cancelled. Nothing was interrupted.",
            failed: "Not interrupted"))
      ])
    #expect(runner.writes.isEmpty)
  }

  @Test func confirmingAnInterruptSendsEscOnce() async throws {
    let (runner, client) = Self.working()
    let gateway = FakeGateway([Self.interrupt, Fixtures.answer("It stopped.")])
    let session = session(gateway, client)
    _ = try await session.ask("stop the demo agent")
    let events = Events()

    let agent = try await session.confirm("a1") { events.append($0) }
    #expect(agent?.paneId == "w1:p1")
    try await session.confirm("a1") { events.append($0) }
    #expect(events.statuses(of: "a1") == [.busy, .done])
    #expect(runner.writes == Self.esc)
    _ = try await session.ask("did it stop?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user confirmed a1; w1:p1 was sent Esc to interrupt it, and should now be waiting at its prompt."))
  }

  @Test func cancellingAnInterruptSendsNothing() async throws {
    let (runner, client) = Self.working()
    let session = session(FakeGateway([Self.interrupt]), client)
    _ = try await session.ask("stop the demo agent")
    let events = Events()

    await session.cancel("a1") { events.append($0) }
    try await session.confirm("a1") { events.append($0) }
    #expect(events.statuses(of: "a1") == [.cancelled])
    #expect(runner.writes.isEmpty)
  }

  @Test func anAgentThatFinishedBeforeTheConfirmFailsWithTheReason() async throws {
    let (runner, client) = Self.working()
    let gateway = FakeGateway([Self.interrupt, Fixtures.answer("It had already finished.")])
    let session = session(gateway, client)
    _ = try await session.ask("stop the demo agent")
    runner.snapshot = Fixtures.snapshot
    let events = Events()

    await #expect(throws: HerdrError.notWorking(paneId: "w1:p1", status: "idle")) {
      try await session.confirm("a1") { events.append($0) }
    }
    let reason = "the agent in w1:p1 isn't working (it's idle), so there's nothing to interrupt"
    #expect(events.statuses(of: "a1") == [.busy, .failed(reason)])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("what happened?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user confirmed a1 but the agent was not interrupted: \(reason)"))
  }

  @Test func askingToInterruptABlockedAgentGoesBackToTheModel() async throws {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "interrupt_agent", #"{"pane_id":"w2:p1"}"#),
      Fixtures.answer("acme is waiting on you."),
    ])
    let (runner, client) = Self.working()
    let turn = try await session(gateway, client).ask("stop the acme agent")

    #expect(turn.actions.isEmpty)
    let result = try #require(gateway.requests.last?.messages.last?.content)
    #expect(result.contains("waiting on you in its terminal"))
    #expect(runner.writes.isEmpty)
  }
}
