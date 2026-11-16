import Foundation
import Testing

@testable import HollerCore

@Suite struct HerdrClientTests {
  @Test func snapshotFlattensLabelsAndIgnoresUnknownFields() async throws {
    let agents = try await Fixtures.client(FakeRunner()).agents()
    #expect(
      agents == [
        HerdrAgent(
          paneId: "w1:p1", kind: "claude", status: "idle", workspace: "demo", tab: "main", tabId: "w1:t1",
          cwd: "/Users/test/Projects/demo", title: "Refactor parser", focused: false),
        HerdrAgent(
          paneId: "w2:p1", kind: "codex", status: "blocked", workspace: "acme", tab: "tests", tabId: "w2:t3",
          cwd: "/Users/test/Clients/acme", title: "Fix flaky test", focused: true),
      ])
  }

  @Test func excludedFoldersAreInvisibleAndUnreadable() async throws {
    let runner = FakeRunner()
    let client = Fixtures.client(runner, excluding: ["/Users/test/Clients"])
    #expect(try await client.agents().map(\.paneId) == ["w1:p1"])
    await #expect(throws: HerdrError.unknownPane("w2:p1")) { try await client.read(paneId: "w2:p1", lines: 50) }
    #expect(!runner.calls.contains { $0.starts(with: ["agent", "read"]) })
  }

  @Test func exclusionMatchesWholeFolderNames() async throws {
    // "/Users/test/Cli" must not exclude "/Users/test/Clients/acme".
    let client = Fixtures.client(FakeRunner(), excluding: ["/Users/test/Cli"])
    #expect(try await client.agents().count == 2)
  }

  @Test func workspaceFilterLimitsToTheDemoWorkspace() async throws {
    let runner = FakeRunner()
    let client = Fixtures.client(runner, workspaces: ["DEMO"])
    #expect(try await client.agents().map(\.paneId) == ["w1:p1"])
    await #expect(throws: HerdrError.unknownPane("w2:p1")) {
      try await client.prompt(Self.acmeAgent, message: "hello")
    }
    #expect(runner.prompts.isEmpty)
  }

  @Test func promptPassesTheMessageAsOneLiteralArgument() async throws {
    let runner = FakeRunner()
    let message = "run `rm -rf ~`; echo $(whoami) && exit"
    try await Fixtures.client(runner).prompt(Fixtures.demoAgent, message: message)
    #expect(runner.prompts == [["agent", "prompt", "w1:p1", message]])
  }

  @Test func promptToUnknownPaneNeverReachesHerdr() async throws {
    let runner = FakeRunner()
    await #expect(throws: HerdrError.unknownPane("w9:p9")) {
      try await Fixtures.client(runner).prompt(Self.agent(in: "w9:p9"), message: "hello")
    }
    await #expect(throws: HerdrError.unknownPane("--help")) {
      try await Fixtures.client(runner).prompt(Self.agent(in: "--help"), message: "hello")
    }
    #expect(runner.prompts.isEmpty)
  }

  /// The fixture snapshot's second agent, as a card would hold it.
  static let acmeAgent = HerdrAgent(
    paneId: "w2:p1", kind: "codex", status: "blocked", workspace: "acme", tab: "tests", tabId: "w2:t3",
    cwd: "/Users/test/Clients/acme", title: "Fix flaky test", focused: true)

  /// The demo agent as a card would hold it, in another pane.
  static func agent(in paneId: String) -> HerdrAgent {
    HerdrAgent(
      paneId: paneId, kind: "claude", status: "idle", workspace: "demo", tab: "main", tabId: "w1:t1",
      cwd: "/Users/test/Projects/demo", title: "", focused: false)
  }

  /// The fixture snapshot with the demo agent's pane (w1:p1) on terminal `id`.
  static func snapshot(demoTerminal id: String) -> String {
    Fixtures.snapshot.replacingOccurrences(
      of: #""pane_id":"w1:p1","tab_id":"w1:t1""#, with: #""pane_id":"w1:p1","tab_id":"w1:t1","terminal_id":"\#(id)""#)
  }

  /// The model names how many lines to read, so the number can be anything.
  @Test func aReadsTimeoutComesFromTheLinesItActuallyAsksFor() {
    #expect(HerdrClient.readTimeout(lines: 40) == .seconds(5))
    #expect(HerdrClient.readTimeout(lines: 2_000) == .seconds(25))
    #expect(HerdrClient.readTimeout(lines: 10_000_000) == .seconds(25))
    #expect(HerdrClient.readTimeout(lines: -5_000) == .seconds(5))
    #expect(HerdrClient.readArguments(paneId: "w1:p1", lines: -5_000).last == "1")
    #expect(HerdrClient.readArguments(paneId: "w1:p1", lines: 10_000_000).last == "2000")
  }

  // MARK: - Names and titles

  /// A title is whatever the pane's program set, often the command it's
  /// running, and a tab can be named anything: both go to the model.
  @Test func terminalTitlesAndTabNamesAreRedacted() async throws {
    let runner = FakeRunner(
      snapshot: Fixtures.snapshot
        .replacingOccurrences(
          of: #""terminal_title_stripped":"Refactor parser""#,
          with: #""terminal_title_stripped":"curl -H 'Authorization: Bearer abcdefghijklmnop' https://example.com""#)
        .replacingOccurrences(of: #""label":"notes""#, with: #""label":"ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789""#)
        .replacingOccurrences(of: #""label":"main""#, with: #""label":"deploy TOKEN=abcdefgh1234""#))
    let state = try await Fixtures.client(runner).state()
    let demo = try #require(state.agents.first)
    #expect(demo.title == "curl -H 'Authorization: Bearer [redacted token]' https://example.com")
    #expect(demo.tab == "deploy TOKEN=[redacted value]")
    #expect(state.workspaces.first?.tabs == ["deploy TOKEN=[redacted value]", "[redacted token]"])
    let list = AssistantPrompt.agentList(state.agents, now: Date())
    #expect(!list.contains("abcdefghijklmnop") && !list.contains("abcdefgh1234"))
    #expect(SpeechHints.keyTerms(for: state.agents).allSatisfy { !$0.contains("abcdefgh1234") })
    // An ordinary name and title come through as they are.
    #expect(state.agents.last?.tab == "tests" && state.agents.last?.title == "Fix flaky test")
  }

  // MARK: - The agent on the card

  /// Herdr starts its pane ids over when it restarts, so w1:p1 can come to
  /// hold someone else's agent while a card for the old one still waits.
  @Test func promptChecksAgainSoAnotherTerminalInThePaneIsLeftAlone() async throws {
    let runner = FakeRunner(snapshot: Self.snapshot(demoTerminal: "term_a"))
    let client = Fixtures.client(runner)
    let queued = try await client.resolve("w1:p1")
    #expect(queued.terminalId == "term_a")

    runner.snapshot = Self.snapshot(demoTerminal: "term_b")
    await #expect(throws: HerdrError.agentChanged("w1:p1")) { try await client.prompt(queued, message: "carry on") }
    #expect(runner.prompts.isEmpty)

    runner.snapshot = Self.snapshot(demoTerminal: "term_a")
    try await client.prompt(queued, message: "carry on")
    #expect(runner.prompts == [["agent", "prompt", "w1:p1", "carry on"]])
  }

  @Test func promptChecksAgainSoAMovedOrRenamedAgentIsLeftAlone() async throws {
    let runner = FakeRunner()
    let client = Fixtures.client(runner)
    let queued = try await client.resolve("w1:p1")

    for (old, new) in [
      (#"{"tab_id":"w1:t1","workspace_id":"w1","label":"main"}"#, #"{"tab_id":"w1:t1","workspace_id":"w1","label":"billing"}"#),
      (#"{"workspace_id":"w1","label":"demo"}"#, #"{"workspace_id":"w1","label":"production"}"#),
      (#""pane_id":"w1:p1","tab_id":"w1:t1""#, #""pane_id":"w1:p1","tab_id":"w1:t2""#),
    ] {
      runner.snapshot = Fixtures.snapshot.replacingOccurrences(of: old, with: new)
      #expect(runner.snapshot != Fixtures.snapshot)
      await #expect(throws: HerdrError.agentChanged("w1:p1")) { try await client.prompt(queued, message: "carry on") }
    }
    #expect(runner.prompts.isEmpty)
    #expect(
      HerdrError.agentChanged("w1:p1").description
        == "w1:p1 no longer holds the agent on the card, so Holler left it alone; ask again")
  }

  /// Older Herdr gives no terminal ids, and then the pane, tab and names decide.
  @Test func aTerminalIdKnownOnOnlyOneSideDoesNotRefuseTheSend() async throws {
    let runner = FakeRunner()
    let client = Fixtures.client(runner)
    let queued = try await client.resolve("w1:p1")
    #expect(queued.terminalId == nil)
    runner.snapshot = Self.snapshot(demoTerminal: "term_a")
    try await client.prompt(queued, message: "carry on")

    let withId = try await client.resolve("w1:p1")
    runner.snapshot = Fixtures.snapshot
    try await client.prompt(withId, message: "and again")
    #expect(runner.prompts.count == 2)
  }

  @Test func aBlockedAgentIsNeverSentAMessageWhateverHerdrWouldDo() async throws {
    let runner = FakeRunner()
    let client = Fixtures.client(runner)
    await #expect(throws: HerdrError.agentBlocked(paneId: "w2:p1")) { try await client.prompt(Self.acmeAgent, message: "yes") }

    // Idle when its card was made, blocked by the time it's confirmed.
    let queued = try await client.resolve("w1:p1")
    runner.snapshot = Fixtures.snapshot(demoAgent: "blocked")
    await #expect(throws: HerdrError.agentBlocked(paneId: "w1:p1")) { try await client.prompt(queued, message: "yes") }
    #expect(runner.prompts.isEmpty)
    #expect(
      HerdrError.agentBlocked(paneId: "w1:p1").description
        == "the agent in w1:p1 is waiting on you in its terminal, so Holler won't send it anything; answer it there")
  }

  @Test func herdrFailureSurfacesItsMessage() async throws {
    let runner = FakeRunner()
    runner.promptResult = CommandResult(exitCode: 1, stdout: "", stderr: "agent_blocked\n")
    await #expect(throws: HerdrError.commandFailed(command: "agent prompt", detail: "agent_blocked")) {
      try await Fixtures.client(runner).prompt(Fixtures.demoAgent, message: "continue")
    }
  }

  @Test func sanitizeStripsControlCharactersButKeepsNewlines() throws {
    #expect(try HerdrClient.sanitize("  next\u{1B}[2J steps\n\tplease\u{07}  ") == "next[2J steps\n\tplease")
    #expect(throws: HerdrError.invalidMessage("empty")) { try HerdrClient.sanitize(" \u{1B} \n") }
    #expect(throws: HerdrError.self) { try HerdrClient.sanitize(String(repeating: "a", count: 2_001)) }
  }

  @Test func anAgentThatStartedWorkingSinceTheSnapshotFallsBackToTheVisibleScreen() async throws {
    // The snapshot still says idle, but Herdr refuses the scrollback read.
    let runner = FakeRunner(readOutput: "Running tests…\n")
    runner.workingPanes = ["w1:p1"]
    let read = try await Fixtures.client(runner).read(paneId: "w1:p1", lines: 60)
    #expect(read.text == PaneText.screenOnly + "\nRunning tests…")
    let sources = runner.calls.filter { $0.starts(with: ["agent", "read"]) }.map { $0[4] }
    #expect(sources == ["recent-unwrapped", "visible"])
  }

  @Test func aWorkingAgentIsReadFromTheVisibleScreenInOneCall() async throws {
    // Herdr would refuse its scrollback, so that read is never attempted.
    let runner = FakeRunner(
      snapshot: Fixtures.snapshot.replacingOccurrences(
        of: #""agent_status":"idle","cwd":"/Users/test/Projects/demo""#,
        with: #""agent_status":"working","cwd":"/Users/test/Projects/demo""#),
      readOutput: "Running tests…\n")
    runner.workingPanes = ["w1:p1"]
    let read = try await Fixtures.client(runner).read(paneId: "w1:p1", lines: 60)
    #expect(read.agent.status == "working")
    // The result says so, so the model can tell the user why the rest is missing.
    #expect(read.text == PaneText.screenOnly + "\nRunning tests…")
    let sources = runner.calls.filter { $0.starts(with: ["agent", "read"]) }.map { $0[4] }
    #expect(sources == ["visible"])
  }

  @Test func theScreenOfAWorkingAgentIsNotMarkedWhenPrefetched() async throws {
    // The prefetch is the screen by design, so it carries no marker and costs what it did.
    let runner = FakeRunner(readOutput: "Running tests…\n")
    runner.workingPanes = ["w1:p1"]
    let agent = try await Fixtures.client(runner).resolve("w1:p1")
    #expect(try await Fixtures.client(runner).readScreen(agent, lines: 60) == "Running tests…")
  }

  @Test func aScrollbackReadGetsTimeToScroll() async throws {
    let runner = FakeRunner()
    let client = Fixtures.client(runner)
    _ = try await client.read(paneId: "w1:p1", lines: 2_000)
    _ = try await client.read(paneId: "w1:p1", lines: 40)
    let reads = zip(runner.calls, runner.timeouts).filter { $0.0.starts(with: ["agent", "read"]) }.map(\.1)
    #expect(reads == [.seconds(25), .seconds(5)])
  }

  @Test func aScrollbackReadThatTimesOutFallsBackToTheScreen() async throws {
    let runner = FakeRunner(readOutput: "Still here.\n")
    runner.slowPanes = ["w1:p1"]
    let client = Fixtures.client(runner)
    let text = try await client.read(paneId: "w1:p1", lines: 2_000, maxCharacters: 200_000).text
    #expect(text == PaneText.readTimedOut + "\nStill here.")
    let sources = runner.calls.filter { $0.starts(with: ["agent", "read"]) }.map { $0[4] }
    #expect(sources == ["recent-unwrapped", "visible"])
    #expect(PaneText.lastLine(text) == "Still here.")
  }

  @Test func aReadCarriesItsOwnCharacterBudget() async throws {
    // 20 lines of 1,000 characters: past the default cut, within a larger one.
    let line = String(repeating: "x", count: 999)
    let runner = FakeRunner(readOutput: Array(repeating: line, count: 20).joined(separator: "\n") + "\n")
    let client = Fixtures.client(runner)
    let whole = try await client.read(paneId: "w1:p1", lines: 60, maxCharacters: 80_000).text
    #expect(whole.count == 20 * 1_000 - 1 && !whole.hasPrefix("["))
    let cut = try await client.read(paneId: "w1:p1", lines: 60).text
    #expect(cut.hasPrefix("[earlier output left out: about 7,900 characters]\n"))
    #expect(cut.hasSuffix(line) && cut.count < whole.count)
  }

  @Test func readRedactsSecretsBeforeTheTextIsSeen() async throws {
    let raw = "export ASSEMBLYAI_API_KEY=3f2a9c8e1b7d4e6f0a1b2c3d4e5f6a7b\ncurl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcDEF123'\nTests passed.\n"
    let runner = FakeRunner(readOutput: raw)
    let read = try await Fixtures.client(runner).read(paneId: "w1:p1", lines: 60)
    #expect(
      read.text
        == "export ASSEMBLYAI_API_KEY=[redacted value]\ncurl -H 'Authorization: Bearer [redacted token]'\nTests passed.")
    #expect(!read.text.contains("3f2a9c8e"))
    #expect(!read.text.contains("eyJ"))
  }

  @Test func readLinesAreClamped() {
    #expect(HerdrClient.readArguments(paneId: "w1:p1", lines: 10_000).last == "2000")
    #expect(HerdrClient.readArguments(paneId: "w1:p1", lines: 2_000).last == "2000")
    #expect(HerdrClient.readArguments(paneId: "w1:p1", lines: 0).last == "1")
  }

  @Test func paneTextDropsChromeAndKeepsTheTail() {
    let raw = "first line   \n\n────────\n  ╭──╮  \nsecond\n\n\n\nthird\n"
    #expect(PaneText.clean(raw) == "first line\n\nsecond\n\nthird")
    #expect(PaneText.clean("abcdefghij", maxCharacters: 4) == "[earlier output left out: about 6 characters]\nghij")
  }

  @Test func aConfirmCardsLastLineIsNeverAMarker() {
    // A working agent's read starts with the screen-only marker; the card wants the agent's words.
    #expect(PaneText.lastLine(PaneText.screenOnly + "\n❯ ") == nil)
    #expect(PaneText.lastLine(PaneText.screenOnly + "\nAdding the toggle.\n❯ ") == "Adding the toggle.")
    #expect(PaneText.lastLine(PaneText.leftOut(5_000) + "\nDone.") == "Done.")
  }

  @Test func aCutReadSaysRoughlyHowMuchWasLeftOut() {
    // Two significant figures: enough to report, never a bare ellipsis to guess at.
    let text = String(repeating: "y", count: 61_347 + 12_000)
    #expect(PaneText.clean(text).hasPrefix("[earlier output left out: about 61,000 characters]\ny"))
    #expect(PaneText.clean(String(repeating: "y", count: 1_234 + 100), maxCharacters: 100).hasPrefix("[earlier output left out: about 1,200 characters]\n"))
    #expect(PaneText.clean(String(repeating: "y", count: 12_000)) == String(repeating: "y", count: 12_000))
  }

  @Test func locateFindsHerdrFromExplicitPath() {
    #expect(HerdrClient.locate(environment: ["HERDR_PATH": "/bin/ls", "HOME": "/nonexistent"])?.path == "/bin/ls")
  }
}
