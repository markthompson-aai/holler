import Foundation
import Testing

@testable import HollerCore

@Suite struct StartAgentTests {
  // MARK: - Workspaces

  @Test func workspacesListTabsAndFoldersWithinTheFilter() async throws {
    let state = try await Fixtures.client(FakeRunner(), excluding: ["/Users/test/Clients"]).state()
    #expect(
      state.workspaces == [
        HerdrWorkspace(
          id: "w1", label: "demo", tabs: ["main", "notes"],
          folders: ["/Users/test/Projects/demo", "/Users/test/Projects/demo/docs"]),
        // Its only tab holds the hidden agent, so the tab's name is hidden too.
        HerdrWorkspace(id: "w2", label: "acme", tabs: [], folders: []),
      ])
    let demoOnly = try await Fixtures.client(FakeRunner(), workspaces: ["Demo"]).state()
    #expect(demoOnly.workspaces.map(\.label) == ["demo"])
  }

  /// A tab's name can say as much as its screen ("acme-merger"), so a tab
  /// with anything in an excluded folder isn't named to the model.
  @Test func aTabWithAPaneInAnExcludedFolderIsNotNamed() async throws {
    let snapshot = Fixtures.snapshot
      // A plain shell, no agent, in an excluded folder in the notes tab.
      .replacingOccurrences(
        of: #"{"pane_id":"w1:p2","workspace_id":"w1","cwd":"/Users/test/Projects/demo/docs"}"#,
        with: #"{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","cwd":"/Users/test/Clients/acme/notes"}"#)
    let all = try await Fixtures.client(FakeRunner(snapshot: snapshot)).state()
    #expect(all.workspaces.map(\.tabs) == [["main", "notes"], ["tests"]])

    let state = try await Fixtures.client(FakeRunner(snapshot: snapshot), excluding: ["/users/test/clients"]).state()
    #expect(state.workspaces.map(\.tabs) == [["main"], []])
    #expect(state.workspaces.map(\.folders) == [["/Users/test/Projects/demo"], []])
    let prompt = AssistantPrompt.userTurn("hello", agents: state.agents, workspaces: state.workspaces, notes: [], now: Date())
    #expect(!prompt.contains("notes") && !prompt.contains("tests") && !prompt.contains("Clients"))
  }

  @Test func theWorkspaceListReachesTheModel() {
    let workspace = HerdrWorkspace(id: "w1", label: "demo", tabs: ["web"], folders: ["/srv/demo/web"])
    let turn = AssistantPrompt.userTurn("start one", agents: [], workspaces: [workspace], notes: [], now: Date())
    #expect(turn.contains("<workspaces>\n- \"demo\" · tabs \"web\" · folders /srv/demo/web\n</workspaces>"))
  }

  // MARK: - Checking a request

  @Test func checkAcceptsAnAllowedWorkspaceAndRealFolder() async throws {
    let folder = try Fixtures.folder()
    let new = try await Fixtures.client(FakeRunner()).checkNewAgent(
      workspace: "DEMO", folder: folder.path + "/../project", tab: "  run\ntests ", task: "  ")
    #expect(new.workspace.id == "w1")
    #expect(new.folder == folder.path)
    #expect(new.tab == "run tests")
    #expect(new.task == nil)
  }

  @Test func checkRejectsWhatTheFilterHidesOrDoesNotExist() async throws {
    let folder = try Fixtures.folder()
    let client = Fixtures.client(FakeRunner(), workspaces: ["demo"])
    await #expect(throws: HerdrError.unknownWorkspace("acme")) {
      try await client.checkNewAgent(workspace: "acme", folder: folder.path, tab: "x", task: nil)
    }
    await #expect(throws: HerdrError.invalidFolder("/nope/missing", reason: "no such folder")) {
      try await client.checkNewAgent(workspace: "demo", folder: "/nope/missing", tab: "x", task: nil)
    }
    await #expect(throws: HerdrError.invalidFolder("demo", reason: "not an absolute path")) {
      try await client.checkNewAgent(workspace: "demo", folder: "demo", tab: "x", task: nil)
    }
    await #expect(throws: HerdrError.invalidMessage("the tab needs a name")) {
      try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: " \n", task: nil)
    }
    // herdr would take either as one of its own options.
    for name in ["--trust-repository", " -x"] {
      await #expect(throws: HerdrError.invalidMessage("a tab name can't start with a dash")) {
        try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: name, task: nil)
      }
    }
    #expect(try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "dark-mode", task: nil).tab == "dark-mode")
  }

  @Test func checkRejectsExcludedFoldersEvenThroughASymlink() async throws {
    let excluded = try Fixtures.folder("customer")
    let link = excluded.deletingLastPathComponent().appendingPathComponent("innocent")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: excluded)
    let client = Fixtures.client(FakeRunner(), excluding: [excluded.path])
    for path in [excluded.path, excluded.path + "/", link.path] {
      await #expect(throws: HerdrError.invalidFolder(path, reason: "that folder is excluded from Holler")) {
        try await client.checkNewAgent(workspace: "demo", folder: path, tab: "x", task: nil)
      }
    }
  }

  // MARK: - Starting

  @Test func startOpensATabStartsClaudeThenSendsTheTask() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let client = Fixtures.client(runner)
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "Run Tests!", task: "go")
    let agent = try await client.start(new)

    #expect(
      runner.writes == [
        ["tab", "create", "--workspace", "w1", "--cwd", folder.path, "--label", "Run Tests!", "--no-focus"],
        ["agent", "start", "run-tests", "--kind", "claude", "--pane", "w1:p9", "--timeout", "30000"],
        ["agent", "prompt", "w1:p9", "go"],
      ])
    #expect(agent.paneId == "w1:p9" && agent.workspace == "demo" && agent.tab == "Run Tests!")
  }

  @Test func withoutATaskNothingIsPrompted() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let client = Fixtures.client(runner)
    _ = try await client.start(try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "t", task: nil))
    #expect(runner.prompts.isEmpty)
  }

  @Test func aTakenNameIsRetriedWithASuffix() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    runner.agentStartResults = [Fixtures.herdrError("agent_name_taken"), Fixtures.herdrError("agent_name_taken")]
    let client = Fixtures.client(runner)
    _ = try await client.start(try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: nil))
    let names = runner.calls.filter { $0.starts(with: ["agent", "start"]) }.map { $0[2] }
    #expect(names == ["web", "web-2", "web-3"])
  }

  @Test func aStartupQuestionLeavesTheTabOpenAndSendsNothing() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    runner.agentStartResults = [Fixtures.herdrError("agent_not_ready", "blocked during startup")]
    let client = Fixtures.client(runner)
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: "go")
    await #expect(throws: HerdrError.startupBlocked(paneId: "w1:p9")) { try await client.start(new) }
    #expect(runner.prompts.isEmpty)
    #expect(!runner.calls.contains { $0.starts(with: ["tab", "close"]) })
  }

  @Test func anyOtherStartFailureClosesTheTab() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    runner.agentStartResults = [CommandResult(exitCode: 1, stdout: "", stderr: "claude: command not found")]
    let client = Fixtures.client(runner)
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: "go")
    await #expect(throws: HerdrError.commandFailed(command: "agent start", detail: "claude: command not found")) {
      try await client.start(new)
    }
    #expect(runner.calls.last == ["tab", "close", "w1:t9"])
    #expect(runner.prompts.isEmpty)
  }

  @Test func startChecksAgainSoAClosedWorkspaceIsNeverUsed() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let client = Fixtures.client(runner)
    let new = try await client.checkNewAgent(workspace: "acme", folder: folder.path, tab: "web", task: nil)
    runner.snapshot = Fixtures.snapshot.replacingOccurrences(of: #"{"workspace_id":"w2","label":"acme"}"#, with: "")
      .replacingOccurrences(of: #""label":"demo"},"#, with: #""label":"demo"}"#)
    await #expect(throws: HerdrError.unknownWorkspace("w2")) { try await client.start(new) }
    #expect(runner.writes.isEmpty)
  }

  @Test func agentNamesAreSlugs() {
    #expect(HerdrClient.agentName("API docs / v2") == "api-docs-v2")
    #expect(HerdrClient.agentName("✨") == "agent")
  }

  // MARK: - Through the session

  func session(_ gateway: FakeGateway, _ runner: FakeRunner) -> AssistantSession {
    AssistantSession(
      gateway: gateway, herdr: Fixtures.client(runner), configuration: .init(model: "test-model", prefetchLines: 0))
  }

  static let startWords = ConfirmCard.Words(
    button: "Start", busy: "Starting…", done: "Started", cancelled: "Cancelled. Nothing was started.", failed: "Didn't finish",
    countdown: "Starting in", runNow: "Start now")

  @Test func aQueuedStartCarriesItsCard() async throws {
    let folder = try Fixtures.folder()
    let arguments = #"{"workspace":"demo","folder":"\#(folder.path)","tab_name":"tests","task":"Run the tests."}"#
    let gateway = FakeGateway([Fixtures.toolCall("c1", "start_agent", arguments)])
    let runner = FakeRunner()
    let events = Events()
    _ = try await session(gateway, runner).ask("start an agent in demo to run the tests") { events.append($0) }

    #expect(
      events.queued.map(\.card) == [
        ConfirmCard(
          kind: .start, verb: "Start Claude in", target: "demo / tests", subtitle: folder.path, body: "Run the tests.",
          placeholder: "No task; it will wait for you.", words: Self.startWords)
      ])
    #expect(runner.writes.isEmpty)
  }

  @Test func aStartWithNoTaskSaysItWillWait() async throws {
    let folder = try Fixtures.folder()
    let arguments = #"{"agent":"codex","workspace":"demo","folder":"\#(folder.path)","tab_name":"web"}"#
    let gateway = FakeGateway([Fixtures.toolCall("c1", "start_agent", arguments)])
    let events = Events()
    _ = try await session(gateway, FakeRunner()).ask("start a codex agent in the demo workspace") { events.append($0) }

    let card = try #require(events.queued.first?.card)
    #expect((card.verb, card.target, card.body) == ("Start Codex in", "demo / web", nil))
    #expect(card.placeholder == "No task; it will wait for you.")
  }

  @Test func aFolderInTheHomeFolderIsShownWithATilde() {
    let home = NSHomeDirectory()
    let new = NewAgent(
      workspace: HerdrWorkspace(id: "w1", label: "demo", tabs: [], folders: []), folder: home + "/Projects/demo", tab: "t",
      task: nil)
    #expect(StartAction(new).card.subtitle == "~/Projects/demo")
  }

  @Test func aBadStartRequestGoesBackToTheModel() async throws {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "start_agent", #"{"workspace":"demo","folder":"/nope","tab_name":"x"}"#),
      Fixtures.answer("That folder doesn't exist."),
    ])
    let runner = FakeRunner()
    let turn = try await session(gateway, runner).ask("start an agent in /nope")

    #expect(turn.actions.isEmpty)
    let result = try #require(gateway.requests.last?.messages.last?.content)
    #expect(result.contains("no such folder"))
    #expect(runner.writes.isEmpty)
  }

  @Test func codexIsStartedWhenAskedAndClaudeIsTheDefault() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let client = Fixtures.client(runner)
    let codex = try await client.checkNewAgent(kind: " Codex", workspace: "demo", folder: folder.path, tab: "web", task: "go")
    #expect(codex.kind == .codex)
    let agent = try await client.start(codex)
    #expect(runner.calls.contains(["agent", "start", "web", "--kind", "codex", "--pane", "w1:p9", "--timeout", "30000"]))
    #expect(agent.kind == "codex")

    let unnamed = try await client.checkNewAgent(kind: "", workspace: "demo", folder: folder.path, tab: "web", task: nil)
    #expect(unnamed.kind == .claude)
  }

  @Test func onlyAllowedKindsCanBeStarted() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let client = Fixtures.client(runner)
    await #expect(throws: HerdrError.unknownAgentKind("gemini")) {
      try await client.checkNewAgent(kind: "gemini", workspace: "demo", folder: folder.path, tab: "web", task: nil)
    }
    #expect(runner.writes.isEmpty)
  }
}
