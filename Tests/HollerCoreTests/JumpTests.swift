import Foundation
import Testing

@testable import HollerCore

@Suite struct JumpTests {
  // MARK: - Focusing

  @Test func focusRunsAgentFocusOnTheResolvedPane() async throws {
    let runner = FakeRunner()
    let agent = try await Fixtures.client(runner).focus(paneId: "w1:p1")
    #expect(agent.workspace == "demo" && agent.tab == "main")
    #expect(runner.writes == [["agent", "focus", "w1:p1"]])
  }

  @Test func aHiddenOrUnknownAgentIsNeverFocused() async throws {
    let runner = FakeRunner()
    let excluded = Fixtures.client(runner, excluding: ["/Users/test/Clients"])
    await #expect(throws: HerdrError.unknownPane("w2:p1")) { try await excluded.focus(paneId: "w2:p1") }
    let filtered = Fixtures.client(runner, workspaces: ["acme"])
    await #expect(throws: HerdrError.unknownPane("w1:p1")) { try await filtered.focus(paneId: "w1:p1") }
    await #expect(throws: HerdrError.unknownPane("w9:p9")) { try await filtered.focus(paneId: "w9:p9") }
    #expect(runner.writes.isEmpty)
  }

  // MARK: - By name, from a summary row

  @Test func aRowIsFoundByItsWorkspaceAndTabIgnoringCase() async throws {
    let runner = FakeRunner()
    let agent = try await Fixtures.client(runner).focus(workspace: "Demo", tab: " MAIN")
    #expect(agent.paneId == "w1:p1")
    #expect(runner.writes == [["agent", "focus", "w1:p1"]])
    _ = try await Fixtures.client(runner).focus(workspace: nil, tab: "tests")
    #expect(runner.writes.last == ["agent", "focus", "w2:p1"])
  }

  @Test func aNameThatFitsNoAgentOrSeveralIsNeverGuessed() async throws {
    let runner = FakeRunner()
    runner.snapshot = runner.snapshot.replacingOccurrences(
      of: #""agents":["#,
      with: #""agents":[{"agent":"codex","agent_status":"idle","cwd":"/Users/test/Projects/demo","pane_id":"w1:p2","tab_id":"w1:t1","workspace_id":"w1"},"#)
    let client = Fixtures.client(runner, excluding: ["/Users/test/Clients"])
    await #expect(throws: HerdrError.severalAgentsNamed("demo / main")) { try await client.focus(workspace: "demo", tab: "main") }
    await #expect(throws: HerdrError.noAgentNamed("demo / notes")) { try await client.focus(workspace: "demo", tab: "notes") }
    // Hidden by the filter: the same as not there.
    await #expect(throws: HerdrError.noAgentNamed("acme / tests")) { try await client.focus(workspace: "acme", tab: "tests") }
    #expect(runner.writes.isEmpty)
  }

  @Test func aRowNamesItsPaneOnlyWhenTheModelAddedOne() {
    #expect(AgentRow(name: "demo / api (w1:p2)", state: .idle, update: "").paneId == "w1:p2")
    #expect(AgentRow(name: "demo / api", state: .idle, update: "").paneId == nil)
  }

  // MARK: - Through the session

  func session(_ gateway: FakeGateway, _ client: HerdrClient) -> AssistantSession {
    AssistantSession(gateway: gateway, herdr: client, configuration: .init(model: "test-model", prefetchLines: 0))
  }

  @Test func focusAgentJumpsStraightAwayWithoutAnotherModelCall() async throws {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "focus_agent", #"{"pane_id":"w1:p1"}"#),
      Fixtures.answer("Anything else?"),
    ])
    let runner = FakeRunner()
    let session = session(gateway, Fixtures.client(runner))
    let turn = try await session.ask("show me the main agent")

    #expect(turn.focused?.paneId == "w1:p1")
    #expect(turn.answer == "Showing demo / main.")
    #expect(turn.actions.isEmpty)
    #expect(gateway.requests.count == 1)
    #expect(runner.writes == [["agent", "focus", "w1:p1"]])

    // A follow-up still sees the jump's answer, as text.
    _ = try await session.ask("thanks")
    let messages = try #require(gateway.requests.last?.messages)
    #expect(!messages.contains { $0.role == .tool })
    #expect(messages.contains { $0.role == .assistant && $0.content == "Showing demo / main." })
  }

  @Test func aRefusedJumpGoesBackToTheModel() async throws {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "focus_agent", #"{"pane_id":"w2:p1"}"#),
      Fixtures.answer("I can't show that one."),
    ])
    let runner = FakeRunner()
    let turn = try await session(gateway, Fixtures.client(runner, workspaces: ["demo"])).ask("show me the acme agent")

    #expect(turn.focused == nil)
    #expect(turn.answer == "I can't show that one.")
    let result = try #require(gateway.requests.last?.messages.last?.content)
    #expect(result.contains("no readable agent in pane w2:p1"))
    #expect(runner.writes.isEmpty)
  }

  @Test func theToolIsOfferedToTheModel() {
    #expect(AssistantTools.all.map(\.name).contains("focus_agent"))
    #expect(AssistantPrompt.system.contains("focus_agent"))
  }
}

@MainActor
@Suite struct JumpControllerTests {
  let runner = FakeRunner()

  func controller(_ gateway: FakeGateway) -> AssistantController {
    let herdr = Fixtures.client(runner)
    return AssistantController(voice: FakeVoice(), herdr: herdr, tapThreshold: .zero) {
      AssistantSession(gateway: gateway, herdr: herdr, configuration: .init(model: "test", prefetchLines: 0))
    }
  }

  @Test func aJumpClosesTheNoteAndCuesTheTerminal() async {
    let controller = controller(FakeGateway([Fixtures.toolCall("c1", "focus_agent", #"{"pane_id":"w1:p1"}"#)]))
    var jumped: [String] = []
    controller.onJumped = { jumped.append($0.paneId) }
    controller.ask("show me the main agent")
    await controller.settle()

    #expect(controller.phase == .idle && controller.exchanges.isEmpty)
    #expect(jumped == ["w1:p1"])
  }

  @Test func aJumpWithACardWaitingKeepsTheNoteAndTheKeyboard() async {
    let gateway = FakeGateway([
      ChatMessage(
        role: .assistant, content: nil,
        toolCalls: [
          ToolCall(id: "c1", name: "prompt_agent", arguments: #"{"pane_id":"w1:p1","message":"carry on"}"#),
          ToolCall(id: "c2", name: "focus_agent", arguments: #"{"pane_id":"w1:p1"}"#),
        ])
    ])
    let controller = controller(gateway)
    var jumped: [String] = []
    controller.onJumped = { jumped.append($0.paneId) }
    controller.ask("tell main to carry on and show it to me")
    await controller.settle()

    #expect(controller.phase == .ready && controller.hasWaitingActions)
    #expect(controller.exchanges.first?.answer == "Showing demo / main.")
    #expect(jumped.isEmpty)
    #expect(runner.writes == [["agent", "focus", "w1:p1"]])
  }

  @Test func aFailedJumpLeavesTheNoteOpenWithTheReason() async {
    let controller = controller(
      FakeGateway([
        Fixtures.toolCall("c1", "focus_agent", #"{"pane_id":"w9:p9"}"#),
        Fixtures.answer("There's no agent called that."),
      ]))
    var jumped: [String] = []
    controller.onJumped = { jumped.append($0.paneId) }
    controller.ask("show me the ghost agent")
    await controller.settle()

    #expect(controller.phase == .ready)
    #expect(controller.exchanges.first?.answer == "There's no agent called that.")
    #expect(jumped.isEmpty)
  }

  // MARK: - Clicking a row

  static let summary = """
    **1 idle.** Nothing needs you.

    - **demo / main**: idle. Finished the parser refactor.
    """

  func summarised(_ extra: [ChatMessage] = []) async -> AssistantController {
    let controller = controller(FakeGateway([Fixtures.answer(Self.summary)] + extra))
    controller.ask("what are my agents up to?")
    await controller.settle()
    return controller
  }

  @Test func clickingARowJumpsToItsAgentAndClosesTheNote() async throws {
    let controller = await summarised()
    var jumped: [String] = []
    controller.onJumped = { jumped.append($0.paneId) }
    guard case .summary(_, _, let rows) = NoteAnswer.parse(try #require(controller.exchanges.first?.answer)) else {
      Issue.record("not a summary")
      return
    }
    controller.jump(to: try #require(rows.first))
    await controller.settle()

    #expect(controller.phase == .idle)
    #expect(jumped == ["w1:p1"])
    #expect(runner.writes == [["agent", "focus", "w1:p1"]])
  }

  @Test func aRowThatCantBeShownLeavesTheNoteOpenWithTheReason() async {
    let controller = await summarised()
    var jumped: [String] = []
    controller.onJumped = { jumped.append($0.paneId) }
    controller.jump(to: AgentRow(name: "demo / gone", state: .idle, update: ""))
    await controller.settle()

    #expect(controller.phase == .ready)
    #expect(controller.notice == #"Couldn't show demo / gone: no agent called "demo / gone" is open."#)
    #expect(jumped.isEmpty)
    #expect(runner.writes.isEmpty)
  }

  @Test func clickingARowWithACardWaitingKeepsTheNote() async {
    let controller = await summarised([
      Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#)
    ])
    controller.ask("tell main to carry on")
    await controller.settle()
    var jumped: [String] = []
    controller.onJumped = { jumped.append($0.paneId) }
    controller.jump(to: AgentRow(name: "demo / main", state: .idle, update: ""))
    await controller.settle()

    #expect(controller.phase == .ready && controller.hasWaitingActions)
    #expect(jumped.isEmpty)
    #expect(runner.writes == [["agent", "focus", "w1:p1"]])
  }

  @Test func aClickWhileHollerWorksIsIgnored() async {
    let controller = await summarised()
    controller.showPreview(phase: .thinking, exchanges: controller.exchanges)
    controller.jump(to: AgentRow(name: "demo / main", state: .idle, update: ""))
    await controller.settle()

    #expect(controller.phase == .thinking)
    #expect(runner.writes.isEmpty)
  }
}
