import Foundation
import Testing

@testable import HollerCore

/// Each action's status, as the session announces it: waiting until the user
/// confirms or cancels, and never acted on twice.
@Suite struct ActionStatusTests {
  func session(_ gateway: FakeGateway, _ client: HerdrClient) -> AssistantSession {
    AssistantSession(gateway: gateway, herdr: client, configuration: .init(model: "test-model", prefetchLines: 0))
  }

  // MARK: - Send

  static let send = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#)

  @Test func confirmingASendGoesBusyThenDone() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.send, Fixtures.answer("Sent.")])
    let session = session(gateway, Fixtures.client(runner))
    let turn = try await session.ask("tell demo to carry on")
    #expect(turn.answer == "Ready to send to demo / main." && gateway.requests.count == 1)
    let events = Events()

    let agent = try await session.confirm("a1") { events.append($0) }
    #expect(agent == Fixtures.demoAgent)
    #expect(events.statuses(of: "a1") == [.busy, .done])
    #expect(runner.writes == [["agent", "prompt", "w1:p1", "carry on"]])
    _ = try await session.ask("did it go?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user confirmed a1; the message was sent to w1:p1."))
  }

  @Test func cancellingASendSendsNothing() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.send, Fixtures.answer("Okay.")])
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("tell demo to carry on")
    let events = Events()

    await session.cancel("a1") { events.append($0) }
    #expect(events.statuses(of: "a1") == [.cancelled])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("never mind")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user cancelled a1; nothing was done."))
  }

  @Test func aSendWhoseAgentHasGoneFailsWithTheReason() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.send, Fixtures.answer("It had gone.")])
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("tell demo to carry on")
    runner.snapshot = Fixtures.snapshotWithoutDemoAgent
    let events = Events()

    await #expect(throws: HerdrError.unknownPane("w1:p1")) { try await session.confirm("a1") { events.append($0) } }
    #expect(events.statuses(of: "a1") == [.busy, .failed("no readable agent in pane w1:p1")])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("what happened?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user confirmed a1 but sending failed: no readable agent in pane w1:p1"))
  }

  @Test func aSendIsConfirmedOrCancelledOnlyOnce() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.send, Fixtures.answer("Sent.")])
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("tell demo to carry on")
    let events = Events()

    // Return pressed twice quickly, then a stray click on Cancel.
    async let first = session.confirm("a1") { events.append($0) }
    async let second = session.confirm("a1") { events.append($0) }
    _ = try await (first, second)
    await session.cancel("a1") { events.append($0) }

    #expect(events.statuses(of: "a1") == [.busy, .done])
    #expect(runner.writes == [["agent", "prompt", "w1:p1", "carry on"]])
    _ = try await session.ask("did it go?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.components(separatedBy: "a1").count == 2)
  }

  @Test func aCancelledSendCanNotBeConfirmed() async throws {
    let runner = FakeRunner()
    let session = session(FakeGateway([Self.send]), Fixtures.client(runner))
    _ = try await session.ask("tell demo to carry on")
    let events = Events()

    await session.cancel("a1") { events.append($0) }
    try await session.confirm("a1") { events.append($0) }
    #expect(events.statuses(of: "a1") == [.cancelled])
    #expect(runner.writes.isEmpty)
  }

  @Test func aRequestThatFailsAfterQueuingASendWithdrawsIt() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.withARead(Self.send), Fixtures.answer("It was dropped.")], failing: [2])
    let session = session(gateway, Fixtures.client(runner))
    let events = Events()

    await #expect(throws: FakeGateway.failure) { try await session.ask("tell demo to carry on") { events.append($0) } }
    try await session.confirm("a1") { events.append($0) }
    await session.cancel("a1") { events.append($0) }
    #expect(events.kinds.contains("queued"))
    #expect(events.statuses(of: "a1") == [.withdrawn])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("did it go?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains(Self.withdrawn("a1")))
    #expect(followUp.components(separatedBy: "a1").count == 2)
  }

  /// The model's message with a read alongside its call, so the turn carries
  /// on to another model call instead of ending on the card.
  static func withARead(_ message: ChatMessage) -> ChatMessage {
    var message = message
    message.toolCalls?.append(ToolCall(id: "r1", name: "read_agents", arguments: #"{"pane_ids":["w1:p1"]}"#))
    return message
  }

  static func withdrawn(_ id: String) -> String {
    "\(id) was dropped because the request that queued it failed; the user never saw it and nothing was done."
  }

  // MARK: - Start

  static func start(in folder: URL) -> ChatMessage {
    Fixtures.toolCall(
      "c1", "start_agent", #"{"workspace":"demo","folder":"\#(folder.path)","tab_name":"tests","task":"Run the tests."}"#)
  }

  @Test func confirmingAStartGoesBusyThenDone() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.start(in: folder), Fixtures.answer("It's running.")])
    let session = session(gateway, Fixtures.client(runner))
    let turn = try await session.ask("start an agent to run the tests")
    #expect(turn.answer == "Ready to start Claude in demo / tests." && gateway.requests.count == 1)
    let events = Events()

    let agent = try await session.confirm("a1") { events.append($0) }
    try await session.confirm("a1") { events.append($0) }
    await session.cancel("a1") { events.append($0) }
    #expect(agent?.paneId == "w1:p9")
    #expect(events.statuses(of: "a1") == [.busy, .done])
    #expect(
      runner.writes == [
        ["tab", "create", "--workspace", "w1", "--cwd", folder.path, "--label", "tests", "--no-focus"],
        ["agent", "start", "tests", "--kind", "claude", "--pane", "w1:p9", "--timeout", "30000"],
        ["agent", "prompt", "w1:p9", "Run the tests."],
      ])
    _ = try await session.ask("is it going?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user confirmed a1; a new Claude agent started in w1:p9 (demo / tests) and was given its task."))
    #expect(followUp.components(separatedBy: "a1").count == 2)
  }

  @Test func confirmingAStartWithNoTaskTellsTheModelItIsWaiting() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let start = Fixtures.toolCall("c1", "start_agent", #"{"agent":"codex","workspace":"demo","folder":"\#(folder.path)","tab_name":"web"}"#)
    let gateway = FakeGateway([start, Fixtures.answer("It's waiting.")])
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("start a codex agent")

    try await session.confirm("a1")
    #expect(runner.prompts.isEmpty)
    _ = try await session.ask("is it up?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user confirmed a1; a new Codex agent started in w1:p9 (demo / web) with no task yet."))
  }

  @Test func cancellingAStartStartsNothing() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.start(in: folder), Fixtures.answer("Okay.")])
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("start an agent to run the tests")
    let events = Events()

    await session.cancel("a1") { events.append($0) }
    await session.cancel("a1") { events.append($0) }
    try await session.confirm("a1") { events.append($0) }
    #expect(events.statuses(of: "a1") == [.cancelled])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("never mind")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user cancelled a1; nothing was done."))
  }

  @Test func aStartThatFailsSaysWhy() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    runner.agentStartResults = [CommandResult(exitCode: 1, stdout: "", stderr: "claude: command not found")]
    let gateway = FakeGateway([Self.start(in: folder), Fixtures.answer("It didn't start.")])
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("start an agent to run the tests")
    let events = Events()

    await #expect(throws: HerdrError.self) { try await session.confirm("a1") { events.append($0) } }
    #expect(events.statuses(of: "a1") == [.busy, .failed("herdr agent start failed: claude: command not found")])
    _ = try await session.ask("what happened?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(
      followUp.contains("The user confirmed a1 but starting the agent failed: herdr agent start failed: claude: command not found"))
  }

  @Test func aStartStoppedByAQuestionFailsWithTheReason() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    runner.agentStartResults = [Fixtures.herdrError("agent_not_ready")]
    let gateway = FakeGateway([Self.start(in: folder), Fixtures.answer("Answer it in the tab.")])
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("start an agent to run the tests")
    let events = Events()

    await #expect(throws: HerdrError.startupBlocked(paneId: "w1:p9")) { try await session.confirm("a1") { events.append($0) } }
    #expect(
      events.statuses(of: "a1") == [
        .busy,
        .failed(
          "The agent opened in w1:p9 but is waiting for you there, usually to ask whether to trust the folder. "
            + "Answer it in that tab; nothing else was sent"),
      ])
    #expect(runner.prompts.isEmpty)
    _ = try await session.ask("what happened?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(
      followUp.contains(
        "The user confirmed a1; Claude opened in w1:p9 (demo / tests) but stopped at a question in its terminal, usually "
          + "whether to trust the folder. Its task was not sent. Once the user has answered it there, the task can be sent "
          + "with prompt_agent."))
  }

  @Test func aRequestThatFailsAfterQueuingAStartWithdrawsIt() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.withARead(Self.start(in: folder)), Fixtures.answer("It was dropped.")], failing: [2])
    let session = session(gateway, Fixtures.client(runner))
    let events = Events()

    await #expect(throws: FakeGateway.failure) {
      try await session.ask("start an agent to run the tests") { events.append($0) }
    }
    try await session.confirm("a1") { events.append($0) }
    #expect(events.statuses(of: "a1") == [.withdrawn])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("is it going?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains(Self.withdrawn("a1")))
  }

  // MARK: - Close

  static let close = Fixtures.toolCall("c1", "close_tab", #"{"pane_id":"w1:p9"}"#)

  @Test func confirmingACloseGoesBusyThenDone() async throws {
    let (runner, client) = CloseTabTests.started()
    let gateway = FakeGateway([Self.close, Fixtures.answer("Closed.")])
    let session = session(gateway, client)
    let turn = try await session.ask("close the dark-mode tab")
    #expect(turn.answer == "Ready to close demo / dark-mode." && gateway.requests.count == 1)
    let events = Events()

    #expect(try await session.confirm("a1") { events.append($0) } == nil)
    try await session.confirm("a1") { events.append($0) }
    await session.cancel("a1") { events.append($0) }
    #expect(events.statuses(of: "a1") == [.busy, .done])
    #expect(runner.writes == [["tab", "close", "w1:t9"]])
    _ = try await session.ask("did it close?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user confirmed a1; the tab demo / dark-mode was closed, ending w1:p9 (claude)."))
    #expect(followUp.components(separatedBy: "a1").count == 2)
  }

  @Test func cancellingACloseClosesNothing() async throws {
    let (runner, client) = CloseTabTests.started()
    let gateway = FakeGateway([Self.close, Fixtures.answer("Okay.")])
    let session = session(gateway, client)
    _ = try await session.ask("close the dark-mode tab")
    let events = Events()

    await session.cancel("a1") { events.append($0) }
    await session.cancel("a1") { events.append($0) }
    try await session.confirm("a1") { events.append($0) }
    #expect(events.statuses(of: "a1") == [.cancelled])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("never mind")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user cancelled a1; nothing was done."))
  }

  @Test func aCloseWhoseTabHasGoneFailsWithTheReason() async throws {
    let (runner, client) = CloseTabTests.started()
    let gateway = FakeGateway([Self.close, Fixtures.answer("It was already gone.")])
    let session = session(gateway, client)
    _ = try await session.ask("close the dark-mode tab")
    runner.snapshot = Fixtures.snapshot
    let events = Events()

    await #expect(throws: HerdrError.unknownTab("w1:t9")) { try await session.confirm("a1") { events.append($0) } }
    #expect(events.statuses(of: "a1") == [.busy, .failed("tab w1:t9 is no longer open")])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("what happened?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("The user confirmed a1 but the tab was not closed: tab w1:t9 is no longer open"))
  }

  @Test func aRequestThatFailsAfterQueuingClosesWithdrawsEachOne() async throws {
    let (runner, client) = CloseTabTests.started()
    // A close in the first round, another in the second, each with a read so
    // the turn carries on, then the third round fails.
    let gateway = FakeGateway(
      [
        Self.withARead(Self.close), Self.withARead(Fixtures.toolCall("c2", "close_tab", #"{"pane_id":"w1:p9"}"#)),
        Fixtures.answer("Both were dropped."),
      ], failing: [3])
    let session = session(gateway, client)
    let events = Events()

    await #expect(throws: FakeGateway.failure) { try await session.ask("close the dark-mode tab") { events.append($0) } }
    try await session.confirm("a2") { events.append($0) }
    #expect(events.queued.map(\.id) == ["a1", "a2"])
    #expect(events.statuses(of: "a1") == [.withdrawn])
    #expect(events.statuses(of: "a2") == [.withdrawn])
    #expect(runner.writes.isEmpty)
    _ = try await session.ask("did it close?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains(Self.withdrawn("a1")))
    #expect(followUp.contains(Self.withdrawn("a2")))
  }
}
