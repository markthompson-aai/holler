import Foundation
import Testing

@testable import HollerCore

@Suite struct WorktreeStartTests {
  /// A client whose worktrees go in a fresh folder, returned with it.
  func client(_ runner: FakeRunner, excluding: [String] = [], workspaces: [String] = []) throws -> (HerdrClient, URL) {
    let worktrees = try Fixtures.folder("worktrees")
    return (Fixtures.client(runner, excluding: excluding, workspaces: workspaces, worktrees: worktrees.path), worktrees)
  }

  // MARK: - Checking a request

  @Test func theWorktreeIsNamedAfterTheTabInItsRepositorysFolder() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let (client, worktrees) = try client(runner)
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "Run Tests!", task: nil, worktree: true)

    #expect(
      new.worktree
        == NewWorktree(repository: "project", branch: "run-tests", path: worktrees.path + "/project/run-tests"))
    #expect(runner.calls.contains(["worktree", "list", "--cwd", folder.path]))
    #expect(runner.writes.isEmpty)
  }

  @Test func withoutAWorktreeHerdrIsNotAskedAboutOne() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let new = try await Fixtures.client(runner).checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: nil)
    #expect(new.worktree == nil)
    #expect(!runner.calls.contains { $0.first == "worktree" })
  }

  @Test func aTakenFolderOrBranchMovesOnToTheNextName() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let (client, worktrees) = try client(runner)
    try FileManager.default.createDirectory(
      at: worktrees.appendingPathComponent("project/web"), withIntermediateDirectories: true)
    runner.worktreeListResult = Fixtures.result([
      "type": "worktree_list",
      "source": ["repo_key": "k", "repo_name": "project", "repo_root": folder.path, "source_checkout_path": folder.path],
      "worktrees": [["path": "/elsewhere/web-2", "branch": "web-2", "label": "web-2"]],
    ])
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: nil, worktree: true)
    #expect(new.worktree?.branch == "web-3")
    #expect(new.worktree?.path == worktrees.path + "/project/web-3")
  }

  @Test func herdrsRefusalIsTheReasonAndHollerNeverTrustsTheRepositoryItself() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    runner.worktreeListResult = Fixtures.herdrError(
      "repository_not_trusted", "repository is not trusted; trust it in Herdr or pass --trust-repository")
    let (client, _) = try client(runner)
    await #expect(
      throws: HerdrError.worktreeRefused("repository is not trusted; trust it in Herdr or pass --trust-repository")
    ) {
      try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: nil, worktree: true)
    }
    #expect(!runner.calls.contains { $0.contains("--trust-repository") })
  }

  @Test func aWorktreeFolderInAnExcludedFolderIsRefusedEvenThroughASymlink() async throws {
    let folder = try Fixtures.folder()
    let excluded = try Fixtures.folder("customer")
    let link = excluded.deletingLastPathComponent().appendingPathComponent("worktrees")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: excluded)
    for worktrees in [excluded, link] {
      let runner = FakeRunner()
      let client = Fixtures.client(runner, excluding: [excluded.path], worktrees: worktrees.path)
      await #expect(
        throws: HerdrError.worktreeRefused("\(worktrees.path)/project/web is in a folder excluded from Holler")
      ) {
        try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: nil, worktree: true)
      }
    }
  }

  @Test func aRepositoryWithAnExcludedFolderInItIsRefused() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let (client, _) = try client(runner, excluding: [folder.path + "/customer-data"])
    await #expect(throws: HerdrError.worktreeRefused("the repository has a folder excluded from Holler in it")) {
      try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: nil, worktree: true)
    }
  }

  @Test func itsOwnWorkspaceMustBeOneTheFilterAllows() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let (client, _) = try client(runner, workspaces: ["demo"])
    await #expect(
      throws: HerdrError.worktreeRefused("it opens as its own workspace, \"web\", and Holler only sees demo")
    ) {
      try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: nil, worktree: true)
    }
    #expect(!runner.calls.contains { $0.first == "worktree" })
  }

  // MARK: - Starting

  @Test func startMakesTheWorktreeStartsTheAgentThereThenSendsTheTask() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let (client, worktrees) = try client(runner)
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "cache fix", task: "go", worktree: true)
    let agent = try await client.start(new)

    let path = worktrees.path + "/project/cache-fix"
    #expect(
      runner.writes == [
        [
          "worktree", "create", "--cwd", folder.path, "--branch", "cache-fix", "--path", path, "--label", "cache fix",
          "--no-focus",
        ],
        ["agent", "start", "cache-fix", "--kind", "claude", "--pane", "w3:p1", "--timeout", "30000"],
        ["agent", "prompt", "w3:p1", "go"],
      ])
    #expect((agent.paneId, agent.workspace, agent.tab, agent.tabId, agent.cwd) == ("w3:p1", "cache fix", "1", "w3:t1", path))
  }

  @Test func aFailedCreateIsHerdrsReason() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let (client, _) = try client(runner)
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: nil, worktree: true)
    runner.worktreeCreateResult = Fixtures.herdrError("repository_not_trusted", "repository is not trusted")
    await #expect(throws: HerdrError.worktreeRefused("repository is not trusted")) { try await client.start(new) }
    #expect(!runner.calls.contains { $0.starts(with: ["agent", "start"]) })
  }

  @Test func aStartFailureClosesTheWorkspaceAndLeavesTheCheckout() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    runner.agentStartResults = [CommandResult(exitCode: 1, stdout: "", stderr: "claude: command not found")]
    let (client, _) = try client(runner)
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: "go", worktree: true)
    await #expect(throws: HerdrError.commandFailed(command: "agent start", detail: "claude: command not found")) {
      try await client.start(new)
    }
    #expect(runner.calls.last == ["workspace", "close", "w3"])
    #expect(!runner.calls.contains { $0.starts(with: ["worktree", "remove"]) || $0.starts(with: ["tab", "close"]) })
  }

  @Test func aStartupQuestionLeavesTheWorktreeOpenAndSendsNothing() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    runner.agentStartResults = [Fixtures.herdrError("agent_not_ready", "blocked during startup")]
    let (client, _) = try client(runner)
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: "go", worktree: true)
    await #expect(throws: HerdrError.startupBlocked(paneId: "w3:p1")) { try await client.start(new) }
    #expect(runner.prompts.isEmpty)
    #expect(!runner.calls.contains { $0.last == "w3" || $0.starts(with: ["tab", "close"]) })
  }

  @Test func aCheckoutHerdrPutsSomewhereExcludedIsClosedBeforeAnyAgentStarts() async throws {
    let folder = try Fixtures.folder()
    let excluded = try Fixtures.folder("customer")
    let runner = FakeRunner()
    let (client, _) = try client(runner, excluding: [excluded.path])
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: "go", worktree: true)
    runner.worktreeCreateResult = Fixtures.result([
      "type": "worktree_created", "workspace": ["workspace_id": "w3", "label": "web"],
      "tab": ["tab_id": "w3:t1", "label": "1"], "root_pane": ["pane_id": "w3:p1"],
      "worktree": ["path": excluded.path + "/web"],
    ])
    await #expect(
      throws: HerdrError.worktreeRefused(
        "Herdr opened it as \"web\" at \(excluded.path)/web, which Holler can't see, so it closed it again")
    ) { try await client.start(new) }
    #expect(runner.calls.last == ["workspace", "close", "w3"])
    #expect(!runner.calls.contains { $0.starts(with: ["agent", "start"]) })
  }

  @Test func aFolderTakenAfterTheCardWasShownIsNeverUsed() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let (client, _) = try client(runner)
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: nil, worktree: true)
    let path = try #require(new.worktree?.path)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    await #expect(throws: HerdrError.worktreeRefused("\(path) was taken after the card was shown")) {
      try await client.start(new)
    }
    #expect(runner.writes.isEmpty)
  }

  // MARK: - Herdr's config and errors

  @Test func theWorktreesFolderComesFromHerdrsConfig() {
    let config = """
      [keys]
      directory = "/not/this"
      [worktrees]  # where checkouts go
      new_worktree = "prefix+shift+g"
      directory = "~/src/worktrees"
      """
    #expect(HerdrClient.worktreesDirectory(config: config) == "~/src/worktrees")
    #expect(HerdrClient.worktreesDirectory(config: "[worktrees]\n# directory = \"~/.herdr/worktrees\"\n") == nil)
    let home = try? Fixtures.folder("home")
    #expect(
      HerdrClient.configuredWorktreesDirectory(environment: ["HOME": home?.path ?? "/nope"]) == "~/.herdr/worktrees")
  }

  @Test func herdrsMessageIsTakenFromItsJSONError() {
    #expect(HerdrClient.herdrMessage(#"{"error":{"code":"x","message":"not a git repository"}}"#) == "not a git repository")
    #expect(HerdrClient.herdrMessage("exit 1") == "exit 1")
  }

  // MARK: - Through the session

  @Test func theCardSaysTheAgentLandsInItsOwnWorkspace() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner()
    let (client, worktrees) = try client(runner)
    let arguments =
      #"{"workspace":"demo","folder":"\#(folder.path)","tab_name":"cache-fix","task":"Try the fix.","worktree":true}"#
    let gateway = FakeGateway([Fixtures.toolCall("c1", "start_agent", arguments)])
    let events = Events()
    let session = AssistantSession(
      gateway: gateway, herdr: client, configuration: .init(model: "test-model", prefetchLines: 0))
    let turn = try await session.ask("start claude in a worktree to try the fix") { events.append($0) }

    #expect(
      events.queued.map(\.card) == [
        ConfirmCard(
          kind: .start, verb: "Start Claude in a worktree,", target: "cache-fix",
          subtitle: worktrees.path + "/project/cache-fix", body: "Try the fix.", placeholder: "No task; it will wait for you.",
          details: [
            .init(label: "Branch", text: "cache-fix, new, from \(folder.path)"),
            .init(label: "Workspace", text: "Its own, \"cache-fix\", not a tab in demo"),
          ],
          words: StartAgentTests.startWords)
      ])
    #expect(turn.answer == "Ready to start Claude in a new worktree, cache-fix.")
    #expect(runner.writes.isEmpty)
  }
}
