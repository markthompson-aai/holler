import Foundation
import Testing

@testable import HollerCore

@Suite struct TurnTimingTests {
  static func turn(actions: Int = 0, spoken: String? = nil, focused: HerdrAgent? = nil) -> AssistantTurn {
    var turn = AssistantTurn(
      answer: "", actions: (0..<actions).map { Action(id: "a\($0 + 1)", SendAction(agent: Fixtures.demoAgent, text: "go")) },
      spoken: spoken, focused: focused, usage: ChatUsage(inputTokens: 5_200, outputTokens: 140, cachedTokens: 3_100),
      requestIds: ["req_1", "req_2"], iterations: 2, elapsed: .milliseconds(3_812), modelElapsed: .milliseconds(3_400),
      herdrElapsed: .milliseconds(2), readElapsed: .milliseconds(48), readOnRelease: true, agentsRead: 3,
      roundModelElapsed: [.milliseconds(2_900), .milliseconds(500)])
    turn.tools = [("list_agents", false), ("prompt_agent", false)]
    return turn
  }

  @Test func aSpokenTurnLogsWhereTheTimeWent() {
    let line = AssistantController.timingLine(Self.turn(actions: 1), transcript: .milliseconds(812), total: .milliseconds(4_640))
    #expect(
      line
        == "turn totalMs=4640 transcriptMs=812 herdrMs=2 readMs=48 readOnRelease=true agentsRead=3 events=off modelMs=3400 "
        + "roundMs=2900,500 toolsMs=410 rounds=2 tools=list_agents,prompt_agent "
        + "tokensIn=5200 tokensCached=3100 tokensOut=140 actions=1 jumped=false readAloud=false request=req_2")
  }

  @Test func aTypedTurnHasNoTranscriptTime() {
    let line = AssistantController.timingLine(Self.turn(focused: Fixtures.demoAgent), transcript: nil, total: .milliseconds(3_820))
    #expect(line.hasPrefix("turn totalMs=3820 transcriptMs=n/a herdrMs=2"))
    #expect(line.contains("jumped=true"))
  }

  @Test func aReadAloudAnswerIsMarked() {
    let line = AssistantController.timingLine(Self.turn(spoken: "Two agents need you."), transcript: nil, total: .seconds(5))
    #expect(line.contains(" readAloud=true "))
  }

  @Test func aFailedToolIsMarkedAndNoToolsSaysSo() {
    var turn = Self.turn()
    turn.tools = [("start_agent", false), ("close_tab", true)]
    #expect(AssistantController.timingLine(turn, transcript: nil, total: .seconds(5)).contains(" tools=start_agent,close_tab! "))
    turn.tools = []
    #expect(AssistantController.timingLine(turn, transcript: nil, total: .seconds(5)).contains(" tools=none "))
  }

  @Test func theSessionRecordsEachToolAndWhetherItFailed() async throws {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "list_agents", "{}"),
      Fixtures.toolCall("c2", "close_tab", #"{"pane_id":"w1:p9"}"#),
      Fixtures.answer("Holler didn't start that tab."),
    ])
    let session = AssistantSession(
      gateway: gateway, herdr: Fixtures.client(FakeRunner(snapshot: CloseTabTests.snapshotWithNewTab)),
      configuration: .init(model: "test", prefetchLines: 0))
    let turn = try await session.ask("close dark mode")
    #expect(turn.tools.map(\.name) == ["list_agents", "close_tab"])
    #expect(turn.tools.map(\.failed) == [false, true])
  }

  @Test func theSessionTimesHerdrSeparatelyFromTheModel() async throws {
    let session = AssistantSession(
      gateway: FakeGateway([Fixtures.answer("ok")]), herdr: Fixtures.client(FakeRunner()),
      configuration: .init(model: "test"))
    let turn = try await session.ask("summarise")
    #expect(turn.herdrElapsed > .zero)
    #expect(turn.herdrElapsed + turn.modelElapsed <= turn.elapsed)
  }

  @Test func eachModelRoundIsTimed() async throws {
    let session = AssistantSession(
      gateway: FakeGateway([Fixtures.toolCall("c1", "list_agents", "{}"), Fixtures.answer("ok")]),
      herdr: Fixtures.client(FakeRunner()), configuration: .init(model: "test", prefetchLines: 0))
    let turn = try await session.ask("check again")
    #expect(turn.roundModelElapsed.count == 2)
    #expect(turn.roundModelElapsed.reduce(.zero, +) == turn.modelElapsed)
  }

  @MainActor
  @Test func theControllerTimesTheTranscriptAndReadsOnReleaseOnlyForSpokenRequests() async {
    let herdr = Fixtures.client(FakeRunner())
    let controller = AssistantController(voice: FakeVoice(), herdr: herdr, tapThreshold: .zero) {
      AssistantSession(gateway: FakeGateway([Fixtures.answer("a"), Fixtures.answer("b")]), herdr: herdr, configuration: .init(model: "test"))
    }
    var lines: [String] = []
    controller.onTiming = { lines.append($0) }
    controller.hotkeyDown()
    controller.hotkeyUp()
    await controller.settle()
    controller.ask("and now?")
    await controller.settle()

    #expect(lines.count == 2)
    #expect(lines.first?.contains("transcriptMs=n/a") == false)
    #expect(lines.last?.contains("transcriptMs=n/a") == true)
    // Herdr is read on release, while the transcript comes in; a typed
    // request has no release to read it on.
    #expect(lines.first?.contains("readOnRelease=true") == true)
    #expect(lines.last?.contains("readOnRelease=false") == true)
  }

  @MainActor
  @Test func aFailedTurnLogsToo() async {
    let herdr = Fixtures.client(FakeRunner())
    let controller = AssistantController(voice: FakeVoice(), herdr: herdr, tapThreshold: .zero) {
      AssistantSession(gateway: FailingGateway(), herdr: herdr, configuration: .init(model: "test"))
    }
    var lines: [String] = []
    controller.onTiming = { lines.append($0) }
    controller.ask("summarise")
    await controller.settle()

    #expect(lines.count == 1)
    #expect(lines.first?.hasPrefix("turn failed totalMs=") == true)
    #expect(lines.first?.contains("transcriptMs=n/a error=") == true)
  }
}

@Suite struct PaneIdTests {
  @Test func thePatternAcceptsHerdrsLetteredIds() throws {
    let pattern = try Regex("^" + AssistantTools.paneIdPattern + "$")
    for id in ["w1:p1", "w6:p1G", "wH:pA", "w12:p30"] { #expect(id.wholeMatch(of: pattern) != nil, "\(id)") }
    for id in ["", "w1", "p1", "w1:t1", "w1:p1 x", "w1:p-1", "w1:p1;"] { #expect(id.wholeMatch(of: pattern) == nil, "\(id)") }
  }

  @Test func everyPaneIdParameterUsesIt() {
    let pattern = JSONValue.string(AssistantTools.paneIdPattern)
    var checked = 0
    for tool in AssistantTools.all {
      let properties = tool.definition.function.parameters["properties"]
      if let paneId = properties?["pane_id"] {
        #expect(paneId["pattern"] == pattern, "\(tool.name)")
        checked += 1
      }
      if let paneIds = properties?["pane_ids"] {
        #expect(paneIds["items"]?["pattern"] == pattern, "\(tool.name)")
        checked += 1
      }
    }
    #expect(checked == 6)
  }

  @Test func aLetteredPaneCanBeMessaged() async throws {
    let runner = FakeRunner(snapshot: Fixtures.snapshot.replacingOccurrences(of: "w1:p1", with: "wH:pA"))
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"wH:pA","message":"carry on"}"#)
    ])
    let session = AssistantSession(gateway: gateway, herdr: Fixtures.client(runner), configuration: .init(model: "test", prefetchLines: 0))
    _ = try await session.ask("tell the main agent to carry on")
    try await session.confirm("a1")
    #expect(runner.prompts == [["agent", "prompt", "wH:pA", "carry on"]])
  }
}
