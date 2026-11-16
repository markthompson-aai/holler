import Foundation
import Testing

@testable import HollerCore

/// Which agents' recent output a request reads up front: every agent at the
/// start of a conversation, then only the agents in focus plus any that
/// changed, seen in the reads Herdr receives.
@Suite struct FocusTests {
  func session(_ gateway: FakeGateway, _ runner: FakeRunner) -> AssistantSession {
    AssistantSession(gateway: gateway, herdr: Fixtures.client(runner), configuration: .init(model: "test-model", prefetchLines: 40))
  }

  /// The panes read up front by the request starting now, after `body` runs it.
  func reads(_ runner: FakeRunner, _ body: () async throws -> Void) async rethrows -> Set<String> {
    let before = runner.reads.count
    try await body()
    return Set(runner.reads.dropFirst(before))
  }

  /// The fixture snapshot with the acme agent (w2:p1) idle instead of blocked.
  static let snapshotWithAcmeIdle = Fixtures.snapshot.replacingOccurrences(
    of: #""agent_status":"blocked""#, with: #""agent_status":"idle""#)

  /// The fixture snapshot with a new agent in the demo workspace's notes tab (w1:p2).
  static let snapshotWithNewAgent = Fixtures.snapshot.replacingOccurrences(
    of: #""agents":["#,
    with: #"""
      "agents":[{"agent":"claude","agent_status":"working","cwd":"/Users/test/Projects/demo/docs","focused":false,
       "pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","terminal_title_stripped":"Docs"},
      """#)

  @Test func theFocusTagNeverReachesTheAnswerOrWhatIsReadAloud() async throws {
    let gateway = FakeGateway([
      Fixtures.answer("**demo / main**: idle.\n<about>w1:p1</about>\n<read_aloud>Demo is idle.</read_aloud>"),
      Fixtures.answer("Both idle.\n\n<about>w1:p1, w2:p1</about>"),
      Fixtures.answer("Demo is still idle.<about>w1:p1"),
    ])
    let session = session(gateway, FakeRunner())

    let spoken = try await session.ask("read me how demo is doing")
    #expect(spoken.answer == "**demo / main**: idle." && spoken.spoken == "Demo is idle.")
    let silent = try await session.ask("and the rest?")
    #expect(silent.answer == "Both idle." && silent.spoken == nil)
    // Cut off by the token limit inside the tag.
    let cut = try await session.ask("still?")
    #expect(cut.answer == "Demo is still idle.")

    // Follow-ups still see which agents earlier answers were about.
    let answers = try #require(gateway.requests.last?.messages).filter { $0.role == .assistant }.map(\.content)
    #expect(
      answers == [
        "**demo / main**: idle.\n<about>w1:p1</about>\n<read_aloud>Demo is idle.</read_aloud>",
        "Both idle.\n<about>w1:p1 w2:p1</about>",
      ])
  }

  @Test func theFirstRequestOfAConversationReadsEveryAgent() async throws {
    let runner = FakeRunner()
    let session = session(FakeGateway([Fixtures.answer("Both idle.")]), runner)
    let read = try await reads(runner) { _ = try await session.ask("what's everyone doing?") }
    #expect(read == ["w1:p1", "w2:p1"])
  }

  @Test func aFollowUpReadsOnlyTheAgentsInFocusButStillListsEveryAgent() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Fixtures.answer("**demo / main**: idle.\n<about>w1:p1</about>"), Fixtures.answer("Yes.")])
    let session = session(gateway, runner)
    _ = try await session.ask("how's the demo agent?")
    let read = try await reads(runner) { _ = try await session.ask("is it done yet?") }

    #expect(read == ["w1:p1"])
    let current = try #require(gateway.requests.last?.messages.last?.content)
    #expect(current.contains("- w1:p1 · claude · idle") && current.contains("- w2:p1 · codex · blocked"))
    #expect(current.contains("<pane id=\"w1:p1\"") && !current.contains("<pane id=\"w2:p1\""))
  }

  @Test func aFollowUpAlsoReadsAgentsWhoseStatusChangedOrThatAppeared() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Fixtures.answer("**demo / main**: idle.\n<about>w1:p1</about>"), Fixtures.answer("ok")])
    let session = session(gateway, runner)
    _ = try await session.ask("how's the demo agent?")
    runner.snapshot = Self.snapshotWithNewAgent.replacingOccurrences(
      of: #""agent_status":"blocked""#, with: #""agent_status":"idle""#)
    let read = try await reads(runner) { _ = try await session.ask("anything else?") }

    #expect(read == ["w1:p1", "w2:p1", "w1:p2"])
  }

  @Test func aChangedTitleAloneDoesNotCount() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Fixtures.answer("**demo / main**: idle.\n<about>w1:p1</about>"), Fixtures.answer("ok")])
    let session = session(gateway, runner)
    _ = try await session.ask("how's the demo agent?")
    runner.snapshot = Fixtures.snapshot.replacingOccurrences(of: "Fix flaky test", with: "Fix the other flaky test")
    let read = try await reads(runner) { _ = try await session.ask("and now?") }

    #expect(read == ["w1:p1"])
  }

  @Test(arguments: [
    Fixtures.toolCall("c1", "read_agents", #"{"pane_ids":["w1:p1"]}"#),
    Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#),
    Fixtures.toolCall("c1", "focus_agent", #"{"pane_id":"w1:p1"}"#),
  ])
  func agentsFromToolCallsJoinTheFocus(_ call: ChatMessage) async throws {
    let runner = FakeRunner()
    // The answer marks no agents, so only the tool call puts w1:p1 in focus.
    let session = session(FakeGateway([call, Fixtures.answer("Done."), Fixtures.answer("ok")]), runner)
    _ = try await session.ask("do something with demo")
    let read = try await reads(runner) { _ = try await session.ask("and now?") }

    #expect(read == ["w1:p1"])
  }

  @Test func theFocusIsEveryAgentMarkedAcrossTheRememberedExchanges() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([
      Fixtures.answer("Demo is idle.\n<about>w1:p1</about>"), Fixtures.answer("Acme is blocked.\n<about>w2:p1</about>"),
      Fixtures.answer("Neither changed."),
    ])
    let session = session(gateway, runner)
    _ = try await session.ask("how's demo?")
    _ = try await session.ask("and acme?")
    let read = try await reads(runner) { _ = try await session.ask("any change?") }

    #expect(read == ["w1:p1", "w2:p1"])
  }

  @Test func aNewConversationReadsEveryAgentAgain() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Fixtures.answer("Demo is idle.\n<about>w1:p1</about>"), Fixtures.answer("Both idle.")])
    let session = session(gateway, runner)
    _ = try await session.ask("how's demo?")
    await session.newConversation()
    let read = try await reads(runner) { _ = try await session.ask("what's everyone doing?") }

    #expect(read == ["w1:p1", "w2:p1"])
  }

  @Test func aStatusChangeSeenByAFailedRequestIsStillReadByTheNextOne() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway(
      [Fixtures.answer("Demo is idle.\n<about>w1:p1</about>"), Fixtures.answer("Acme is idle now.")], failing: [2])
    let session = session(gateway, runner)
    _ = try await session.ask("how's demo?")
    runner.snapshot = Self.snapshotWithAcmeIdle
    await #expect(throws: FakeGateway.failure) { try await session.ask("anything new?") }
    let read = try await reads(runner) { _ = try await session.ask("anything new?") }

    #expect(read == ["w1:p1", "w2:p1"])
  }

  @Test func theTurnCountsTheAgentsReadUpFront() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Fixtures.answer("Demo is idle.\n<about>w1:p1</about>"), Fixtures.answer("Yes.")])
    let session = session(gateway, runner)
    let first = try await session.ask("how's demo?")
    let followUp = try await session.ask("is it done?")

    #expect(first.agentsRead == 2 && followUp.agentsRead == 1)
  }

  @Test func theSystemPromptExplainsTheFocusTagAndReadingOtherAgents() {
    #expect(AssistantPrompt.system.contains("<about>"))
    #expect(AssistantPrompt.system.contains("Output for other agents isn't included"))
  }
}
