import Foundation
import Testing

@testable import HollerCore

@Suite struct CloseTabTests {
  /// The fixture snapshot plus a tab Holler could have started: demo / dark-mode
  /// (w1:t9), with a working Claude in w1:p9 whose session is `s-9`.
  static let snapshotWithNewTab = Fixtures.snapshot
    .replacingOccurrences(
      of: #""agents":["#,
      with: #""agents":[{"agent":"claude","agent_status":"working","cwd":"/Users/test/Projects/demo","pane_id":"w1:p9","tab_id":"w1:t9","workspace_id":"w1","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s-9"},"terminal_id":"term_9"},"#)
    .replacingOccurrences(of: #""tabs":["#, with: #""tabs":[{"tab_id":"w1:t9","workspace_id":"w1","label":"dark-mode"},"#)
    .replacingOccurrences(
      of: #""panes":["#,
      with: #""panes":[{"pane_id":"w1:p9","tab_id":"w1:t9","workspace_id":"w1","cwd":"/Users/test/Projects/demo"},"#)

  /// A client that started w1:t9, and the runner behind it.
  static func started(excluding: [String] = [], workspaces: [String] = []) -> (FakeRunner, HerdrClient) {
    let runner = FakeRunner(snapshot: snapshotWithNewTab, readOutput: "⏺ Adding the toggle.\n\n❯ \n⏵⏵ auto mode on\n")
    let client = Fixtures.client(runner, excluding: excluding, workspaces: workspaces)
    client.startedTabs.insert(Self.darkMode)
    return (runner, client)
  }

  /// The record of starting demo / dark-mode.
  static let darkMode = StartedTab(tabId: "w1:t9", paneId: "w1:p9", terminalId: "term_9", sessionId: "s-9")

  /// A file to keep started tabs in, in a fresh folder.
  static func file() throws -> URL {
    try Fixtures.folder("support").appendingPathComponent("started-tabs.json")
  }

  // MARK: - Which tabs

  @Test func startingAnAgentRecordsItsTab() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner(snapshot: Self.snapshotWithNewTab)
    let client = Fixtures.client(runner)
    let copy = client
    _ = try await client.start(try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "t", task: nil))
    #expect(try await copy.state().startedTabs == ["w1:t9"])
  }

  @Test func aStartThatFailsAndClosesItsTabForgetsIt() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner(snapshot: Self.snapshotWithNewTab)
    runner.agentStartResults = [CommandResult(exitCode: 1, stdout: "", stderr: "claude: command not found")]
    let client = Fixtures.client(runner)
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: nil)
    _ = try? await client.start(new)
    #expect(try await client.state().startedTabs.isEmpty)
  }

  @Test func aStartBlockedAtAQuestionStillCountsAsHollers() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner(snapshot: Self.snapshotWithNewTab)
    runner.agentStartResults = [Fixtures.herdrError("agent_not_ready")]
    let client = Fixtures.client(runner)
    let new = try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "web", task: nil)
    _ = try? await client.start(new)
    #expect(try await client.state().startedTabs == ["w1:t9"])
  }

  /// Herdr gives no session for Codex, or for Claude at the trust question.
  @Test func aTabWhoseAgentHasNoSessionIsHollersByItsTerminal() async throws {
    let (folder, file) = (try Fixtures.folder(), try Self.file())
    let runner = FakeRunner(snapshot: Self.snapshotWithoutSession)
    let client = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: runner, startedTabsFile: file)
    _ = try await client.start(try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "t", task: nil))
    #expect(try await client.state().startedTabs == ["w1:t9"])
    let saved = try JSONDecoder().decode([StartedTab].self, from: Data(contentsOf: file))
    #expect(saved == [StartedTab(tabId: "w1:t9", paneId: "w1:p9", terminalId: "term_9", sessionId: nil)])

    let after = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: runner, startedTabsFile: file)
    try await after.close(try await after.checkClose(paneId: "w1:p9"))
    #expect(runner.writes.last == ["tab", "close", "w1:t9"])
  }

  @Test func aSessionThatTurnsUpLaterLeavesTheTabHollers() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner(snapshot: Self.snapshotWithoutSession)
    let client = Fixtures.client(runner)
    _ = try await client.start(try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "t", task: nil))
    runner.snapshot = Self.snapshotWithNewTab
    #expect(try await client.state().startedTabs == ["w1:t9"])
    _ = try await client.checkClose(paneId: "w1:p9")
  }

  /// After Herdr restarts, a tab recorded by its terminal alone is someone
  /// else's once another terminal is in its pane.
  @Test func aTabRecordedByItsTerminalIsntHollersWithAnotherTerminal() async throws {
    let file = try Self.file()
    StartedTabs(file: file).insert(StartedTab(tabId: "w1:t9", paneId: "w1:p9", terminalId: "term_9", sessionId: nil))
    let runner = FakeRunner(snapshot: Self.snapshotWithoutSession.replacingOccurrences(of: "term_9", with: "term_other"))
    let client = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: runner, startedTabsFile: file)
    #expect(try await client.state().startedTabs.isEmpty)
    await #expect(throws: HerdrError.notStartedByHoller(tab: "dark-mode")) { try await client.checkClose(paneId: "w1:p9") }
  }

  @Test func aTabWhoseAgentHerdrCantIdentifyIsntHollers() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner(snapshot: Self.snapshotWithoutIds)
    let client = Fixtures.client(runner)
    _ = try await client.start(try await client.checkNewAgent(workspace: "demo", folder: folder.path, tab: "t", task: nil))
    #expect(try await client.state().startedTabs.isEmpty)
    await #expect(throws: HerdrError.notStartedByHoller(tab: "dark-mode")) { try await client.checkClose(paneId: "w1:p9") }
  }

  /// The new tab before Herdr knows its agent's session.
  static let snapshotWithoutSession = snapshotWithNewTab.replacingOccurrences(
    of: #","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s-9"}"#, with: "")

  /// The new tab with neither a session nor a terminal id.
  static let snapshotWithoutIds = snapshotWithoutSession.replacingOccurrences(of: #","terminal_id":"term_9""#, with: "")

  @Test func theAgentListMarksTabsHollerStarted() async throws {
    let (_, client) = Self.started()
    let state = try await client.state()
    let list = AssistantPrompt.agentList(state.agents, startedTabs: state.startedTabs, now: Date())
    #expect(list.contains(#"w1:p9 · claude · working · workspace "demo" / tab "dark-mode" · folder /Users/test/Projects/demo · started by Holler"#))
    #expect(!list.contains(#"tab "main" · folder /Users/test/Projects/demo · title "Refactor parser" · started by Holler"#))
  }

  // MARK: - Across restarts

  @Test func aTabStartedBeforeHollerRestartedCanStillBeClosed() async throws {
    let (folder, file) = (try Fixtures.folder(), try Self.file())
    let runner = FakeRunner(snapshot: Self.snapshotWithNewTab)
    let before = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: runner, startedTabsFile: file)
    _ = try await before.start(try await before.checkNewAgent(workspace: "demo", folder: folder.path, tab: "t", task: nil))

    let after = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: runner, startedTabsFile: file)
    try await after.close(try await after.checkClose(paneId: "w1:p9"))
    #expect(runner.writes.last == ["tab", "close", "w1:t9"])
    let reloaded = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: runner, startedTabsFile: file)
    #expect(reloaded.startedTabs.open(in: try HerdrSnapshot.decode(Self.snapshotWithNewTab)).isEmpty)
  }

  /// After Herdr restarts, w1:t9 is someone else's tab: same ids, another agent.
  @Test func aSavedTabIdFromAnEarlierHerdrRunIsNeverHollers() async throws {
    let file = try Self.file()
    StartedTabs(file: file).insert(Self.darkMode)
    let runner = FakeRunner(snapshot: Self.snapshotWithNewTab.replacingOccurrences(of: #""value":"s-9""#, with: #""value":"s-other""#))
    let client = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: runner, startedTabsFile: file)

    #expect(try await client.state().startedTabs.isEmpty)
    await #expect(throws: HerdrError.notStartedByHoller(tab: "dark-mode")) { try await client.checkClose(paneId: "w1:p9") }
    let tab = TabToClose(tabId: "w1:t9", workspace: "demo", tab: "dark-mode", agents: [])
    await #expect(throws: HerdrError.notStartedByHoller(tab: "dark-mode")) { try await client.close(tab) }
    #expect(runner.writes.isEmpty)
  }

  @Test func aSavedTabIsForgottenOnceItHasClosed() async throws {
    let file = try Self.file()
    StartedTabs(file: file).insert(Self.darkMode)
    let client = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: FakeRunner(), startedTabsFile: file)
    #expect(try await client.state().startedTabs.isEmpty)
    #expect(StartedTabs(file: file).open(in: try HerdrSnapshot.decode(Self.snapshotWithNewTab)).isEmpty)
  }

  /// After Herdr restarts, a saved tab id can name a tab whose pane holds
  /// another terminal: that tab is forgotten for good, not kept in the file.
  @Test func aSavedTabWhosePaneHoldsAnotherTerminalIsForgotten() async throws {
    let file = try Self.file()
    StartedTabs(file: file).insert(Self.darkMode)
    let runner = FakeRunner(snapshot: Self.snapshotWithoutSession.replacingOccurrences(of: "term_9", with: "term_other"))
    let client = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: runner, startedTabsFile: file)
    #expect(try await client.state().startedTabs.isEmpty)
    #expect(try JSONDecoder().decode([StartedTab].self, from: Data(contentsOf: file)).isEmpty)
  }

  /// The tab is open but the pane Holler started the agent in has closed.
  @Test func aSavedTabWhosePaneHasClosedIsForgotten() async throws {
    let file = try Self.file()
    StartedTabs(file: file).insert(Self.darkMode)
    let snapshot = Self.snapshotWithNewTab
      .replacingOccurrences(
        of: #"{"agent":"claude","agent_status":"working","cwd":"/Users/test/Projects/demo","pane_id":"w1:p9","tab_id":"w1:t9","workspace_id":"w1","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s-9"},"terminal_id":"term_9"},"#,
        with: "")
      .replacingOccurrences(of: #"{"pane_id":"w1:p9","tab_id":"w1:t9","workspace_id":"w1","cwd":"/Users/test/Projects/demo"},"#, with: "")
    #expect(snapshot.contains(#""label":"dark-mode""#) && !snapshot.contains("w1:p9"))
    let runner = FakeRunner(snapshot: snapshot)
    let client = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: runner, startedTabsFile: file)
    #expect(try await client.state().startedTabs.isEmpty)
    #expect(try JSONDecoder().decode([StartedTab].self, from: Data(contentsOf: file)).isEmpty)
  }

  @Test func aSavedTabWhoseAgentHerdrBrieflyCantSeeIsKept() async throws {
    let file = try Self.file()
    StartedTabs(file: file).insert(Self.darkMode)
    let runner = FakeRunner(snapshot: Self.snapshotWithoutSession)
    let client = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: runner, startedTabsFile: file)
    #expect(try await client.state().startedTabs.isEmpty)
    runner.snapshot = Self.snapshotWithNewTab
    #expect(try await client.state().startedTabs == ["w1:t9"])
  }

  @Test func theTabMustStillHaveTheAgentInThePaneHollerStartedItIn() throws {
    let snapshot = try HerdrSnapshot.decode(Self.snapshotWithNewTab)
    let moved = [
      StartedTab(tabId: "w1:t9", paneId: "w1:p1", terminalId: "term_9", sessionId: "s-9"),
      StartedTab(tabId: "w1:t1", paneId: "w1:p9", terminalId: "term_9", sessionId: "s-9"),
      StartedTab(tabId: "w1:t9", paneId: "w1:p9", terminalId: "term_other", sessionId: "s-9"),
    ]
    #expect(moved.allSatisfy { !$0.isOpen(in: snapshot) })
    #expect(StartedTab(tabId: "w1:t9", paneId: "w1:p9", terminalId: nil, sessionId: "s-9").isOpen(in: snapshot))
    #expect(StartedTab(tabId: "w1:t9", paneId: "w1:p9", terminalId: "term_9", sessionId: nil).isOpen(in: snapshot))
    #expect(!StartedTab(tabId: "w1:t9", paneId: "w1:p9", terminalId: "term_9", sessionId: "s-other").isOpen(in: snapshot))
    #expect(!StartedTab(tabId: "w1:t9", paneId: "w1:p9", terminalId: nil, sessionId: nil).isOpen(in: snapshot))
    #expect(Self.darkMode.isOpen(in: snapshot))
  }

  // MARK: - Checking a request

  @Test func checkDescribesTheTabWithoutClosingIt() async throws {
    let (runner, client) = Self.started()
    let tab = try await client.checkClose(paneId: "w1:p9")
    #expect(tab.tabId == "w1:t9" && tab.workspace == "demo" && tab.tab == "dark-mode")
    #expect(tab.agents.map(\.agent.paneId) == ["w1:p9"])
    #expect(tab.agents.first?.lastLine == "Adding the toggle.")
    #expect(runner.writes.isEmpty)
  }

  @Test func aTabHollerDidNotStartIsRefused() async throws {
    let (runner, client) = Self.started()
    await #expect(throws: HerdrError.notStartedByHoller(tab: "main")) { try await client.checkClose(paneId: "w1:p1") }
    #expect(runner.writes.isEmpty)
  }

  @Test func aTabWithAPaneInAnExcludedFolderIsRefused() async throws {
    let (runner, client) = Self.started(excluding: ["/Users/test/Clients"])
    runner.snapshot = runner.snapshot.replacingOccurrences(
      of: #""panes":["#, with: #""panes":[{"pane_id":"w1:p10","tab_id":"w1:t9","workspace_id":"w1","cwd":"/Users/test/Clients/acme"},"#)
    await #expect(throws: HerdrError.tabHasHiddenPanes(tab: "dark-mode")) { try await client.checkClose(paneId: "w1:p9") }
    #expect(runner.writes.isEmpty)
  }

  @Test func aHiddenOrUnknownPaneIsRefused() async throws {
    let (runner, client) = Self.started(workspaces: ["acme"])
    await #expect(throws: HerdrError.unknownPane("w1:p9")) { try await client.checkClose(paneId: "w1:p9") }
    await #expect(throws: HerdrError.unknownPane("w9:p9")) { try await client.checkClose(paneId: "w9:p9") }
    #expect(runner.writes.isEmpty)
  }

  // MARK: - Closing

  @Test func closeRunsTabCloseAndForgetsTheTab() async throws {
    let (runner, client) = Self.started()
    let tab = try await client.checkClose(paneId: "w1:p9")
    try await client.close(tab)
    #expect(runner.writes == [["tab", "close", "w1:t9"]])
    #expect(try await client.state().startedTabs.isEmpty)
  }

  @Test func closeChecksAgainSoAGoneTabIsNeverClosed() async throws {
    let (runner, client) = Self.started()
    let tab = try await client.checkClose(paneId: "w1:p9")
    runner.snapshot = Fixtures.snapshot
    await #expect(throws: HerdrError.unknownTab("w1:t9")) { try await client.close(tab) }
    #expect(runner.writes.isEmpty)
  }

  @Test func closeChecksAgainSoAPaneOpenedSinceInAnExcludedFolderStopsIt() async throws {
    let (runner, client) = Self.started(excluding: ["/Users/test/Clients"])
    let tab = try await client.checkClose(paneId: "w1:p9")
    runner.snapshot = runner.snapshot.replacingOccurrences(
      of: #""panes":["#, with: #""panes":[{"pane_id":"w1:p10","tab_id":"w1:t9","workspace_id":"w1","cwd":"/Users/test/Clients/acme"},"#)
    await #expect(throws: HerdrError.tabHasHiddenPanes(tab: "dark-mode")) { try await client.close(tab) }
    #expect(runner.writes.isEmpty)
  }

  @Test func closeRefusesATabHollerDidNotStartEvenIfAskedDirectly() async throws {
    let (runner, client) = Self.started()
    let main = TabToClose(tabId: "w1:t1", workspace: "demo", tab: "main", agents: [])
    await #expect(throws: HerdrError.notStartedByHoller(tab: "main")) { try await client.close(main) }
    #expect(runner.writes.isEmpty)
  }

  // MARK: - Through the session

  func session(_ gateway: FakeGateway, _ client: HerdrClient) -> AssistantSession {
    AssistantSession(gateway: gateway, herdr: client, configuration: .init(model: "test-model", prefetchLines: 0))
  }

  @Test func theModelSeesWhichTabsHollerStarted() async throws {
    let gateway = FakeGateway([Fixtures.answer("dark-mode is one of mine.")])
    let (_, client) = Self.started()
    _ = try await session(gateway, client).ask("which tabs did you start?")

    let context = try #require(gateway.requests.first?.messages.last?.content)
    #expect(context.contains("· started by Holler"))
  }

  static let closeWords = ConfirmCard.Words(
    button: "Close", busy: "Closing…", done: "Closed", cancelled: "Cancelled. Nothing was closed.", failed: "Not closed")

  /// The card for closing dark-mode, queued through a session on `client`.
  func queuedCard(_ client: HerdrClient) async throws -> ConfirmCard {
    let gateway = FakeGateway([Fixtures.toolCall("c1", "close_tab", #"{"pane_id":"w1:p9"}"#)])
    let events = Events()
    _ = try await session(gateway, client).ask("close the dark-mode tab") { events.append($0) }
    return try #require(events.queued.first?.card)
  }

  @Test func aQueuedCloseCarriesItsCard() async throws {
    let (runner, client) = Self.started()
    #expect(
      try await queuedCard(client)
        == ConfirmCard(
          kind: .close, verb: "Close", target: "demo / dark-mode",
          details: [.init(label: "Claude · working", text: "Adding the toggle.", placeholder: "No output yet.")],
          warnings: ["dark-mode is working; closing stops it."], words: Self.closeWords))
    #expect(runner.writes.isEmpty)
  }

  @Test func aBlockedAgentIsShownAsNeedingYouAndWarnedAbout() async throws {
    let (runner, client) = Self.started()
    runner.snapshot = runner.snapshot.replacingOccurrences(
      of: #""agent_status":"working","cwd":"/Users/test/Projects/demo","pane_id":"w1:p9""#,
      with: #""agent_status":"blocked","cwd":"/Users/test/Projects/demo","pane_id":"w1:p9""#)
    let card = try await queuedCard(client)
    #expect(card.details == [.init(label: "Claude · needs you", text: "Adding the toggle.", placeholder: "No output yet.")])
    #expect(card.warnings == ["dark-mode is waiting on you; closing ends it unanswered."])
  }

  @Test func withTwoAgentsEachHasARowAndOnlyTheBusyOneAWarning() async throws {
    let (runner, client) = Self.started()
    runner.readOutput = "❯ \n"
    runner.snapshot = runner.snapshot
      .replacingOccurrences(
        of: #""agents":["#,
        with: #""agents":[{"agent":"codex","agent_status":"done","cwd":"/Users/test/Projects/demo","pane_id":"w1:p10","tab_id":"w1:t9","workspace_id":"w1"},"#)
      .replacingOccurrences(
        of: #""panes":["#,
        with: #""panes":[{"pane_id":"w1:p10","tab_id":"w1:t9","workspace_id":"w1","cwd":"/Users/test/Projects/demo"},"#)
    let card = try await queuedCard(client)
    #expect(
      card.details == [
        .init(label: "Codex · idle", text: nil, placeholder: "No output yet."),
        .init(label: "Claude · working", text: nil, placeholder: "No output yet."),
      ])
    #expect(card.warnings == ["Claude (w1:p9) is working; closing stops it."])
  }

  @Test func askingToCloseSomeoneElsesTabGoesBackToTheModel() async throws {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "close_tab", #"{"pane_id":"w1:p1"}"#),
      Fixtures.answer("I can only close tabs I started."),
    ])
    let (runner, client) = Self.started()
    let turn = try await session(gateway, client).ask("close the main tab")

    #expect(turn.actions.isEmpty)
    let result = try #require(gateway.requests.last?.messages.last?.content)
    #expect(result.contains("Holler can only close tabs it started"))
    #expect(runner.writes.isEmpty)
  }

  @Test func aTabStartedInOneNoteCanBeClosedFromTheNext() async throws {
    let folder = try Fixtures.folder()
    let runner = FakeRunner(snapshot: Self.snapshotWithNewTab)
    let client = Fixtures.client(runner)
    let start = FakeGateway([
      Fixtures.toolCall("c1", "start_agent", #"{"workspace":"demo","folder":"\#(folder.path)","tab_name":"dark-mode"}"#)
    ])
    let first = session(start, client)
    _ = try await first.ask("start an agent for dark mode")
    try await first.confirm("a1")

    let close = FakeGateway([Fixtures.toolCall("c1", "close_tab", #"{"pane_id":"w1:p9"}"#)])
    let second = session(close, client)
    _ = try await second.ask("close the dark-mode tab")
    try await second.confirm("a1")
    #expect(runner.writes.last == ["tab", "close", "w1:t9"])
  }

  // MARK: - Last line

  @Test func theLastLineIsTheOutputAboveThePrompt() {
    let claude = """
      ⏺ The 90-second sleep is running in the background.
      ✻ Baked for 5s · done 15:22
      ────────────────
      ❯ run it in the background then
      ────────────────
        ⏵⏵ auto mode on · 1 shell
      """
    #expect(PaneText.lastLine(claude) == "The 90-second sleep is running in the background.")
    let codex = """
      • Said hello and stopped.

      › Ask Codex to do anything
        GPT-6-Luna default · ~/Projects/holler
        ← for agents · ? for shortcuts
      """
    #expect(PaneText.lastLine(codex) == "Said hello and stopped.")
    #expect(PaneText.lastLine("❯ \n") == nil)
    #expect(PaneText.lastLine(String(repeating: "a", count: 300))?.count == 140)
  }
}
