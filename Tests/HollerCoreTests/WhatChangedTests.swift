import Foundation
import Testing

@testable import HollerCore

/// What the watcher adds to a request: how long each agent has waited, and
/// what changed since the user last asked. Without one, requests are as before.
@Suite struct WhatChangedTests {
  let date = TestDate()

  func watcher(_ runner: FakeRunner, source: FakeEventSource? = nil, file: URL? = nil) -> HerdrWatcher {
    let date = date
    return HerdrWatcher(
      herdr: Fixtures.client(runner), source: source, file: file, now: { date.now }, retryDelays: [.milliseconds(10)],
      settle: .milliseconds(1))
  }

  func session(_ gateway: FakeGateway, _ runner: FakeRunner, watcher: HerdrWatcher?) -> AssistantSession {
    AssistantSession(
      gateway: gateway, herdr: Fixtures.client(runner), watcher: watcher,
      configuration: .init(model: "test-model", prefetchLines: 40))
  }

  static func answers(_ count: Int) -> FakeGateway {
    FakeGateway((0..<count).map { _ in Fixtures.answer("Fine.") })
  }

  /// The fixture snapshot with the demo agent (w1:p1) working instead of idle.
  static let snapshotWithDemoWorking = Fixtures.snapshot.replacingOccurrences(
    of: #""agent_status":"idle""#, with: #""agent_status":"working""#)

  @Test func theAgentListSaysHowLongEachHasWaited() async throws {
    let (runner, gateway) = (FakeRunner(), Self.answers(2))
    let session = session(gateway, runner, watcher: watcher(runner))

    _ = try await session.ask("what's going on?")
    // Just seen, already waiting: nothing is known yet about for how long.
    #expect(!gateway.lastUserRequest.contains("stopped working"))

    date.advance(minutes: 12)
    _ = try await session.ask("and now?")
    let request = gateway.lastUserRequest
    #expect(request.contains("- w1:p1 · claude · idle, stopped working at least 12 min ago · workspace \"demo\""))
    #expect(request.contains("- w2:p1 · codex · blocked, stopped working at least 12 min ago · workspace \"acme\""))
  }

  @Test func eventsTimeAWaitExactly() async throws {
    let (runner, gateway, source) = (FakeRunner(), Self.answers(1), FakeEventSource())
    let watcher = watcher(runner, source: source)
    await watcher.start()
    await eventually { source.subscriptions.count == 1 }
    source.send(.subscribed)
    await eventually { await watcher.isLive }

    date.advance(minutes: 5)
    runner.snapshot = Self.snapshotWithDemoWorking
    source.send(.statusChanged(paneId: "w1:p1", status: "working"))
    await eventually { await watcher.watching("w1:p1")?.status == "working" }
    date.advance(minutes: 12)
    let turn = try await session(gateway, runner, watcher: watcher).ask("how long has demo been at it?")

    #expect(gateway.lastUserRequest.contains("- w1:p1 · claude · working for 12 min · workspace"))
    #expect(turn.eventsLive == true)
    await watcher.stop()
  }

  @Test func aFollowUpListsWhatChangedSinceTheLastRequest() async throws {
    let (runner, gateway) = (FakeRunner(), Self.answers(2))
    let session = session(gateway, runner, watcher: watcher(runner))

    _ = try await session.ask("what's going on?")
    #expect(!gateway.lastUserRequest.contains("<changes"))

    date.advance(minutes: 9)
    runner.snapshot = FocusTests.snapshotWithAcmeIdle
    _ = try await session.ask("what's changed since I last asked?")
    let request = gateway.lastUserRequest
    #expect(request.contains(#"ago="9 min">"#))
    #expect(request.contains("- w2:p1 (acme / tests): blocked → idle by "))
    #expect(!request.contains("w1:p1 (demo / main)"))
  }

  @Test func anAgentThatChangedAndChangedBackIsStillRead() async throws {
    let (runner, gateway) = (FakeRunner(), Self.answers(2))
    let watcher = watcher(runner)
    let session = session(gateway, runner, watcher: watcher)
    _ = try await session.ask("what's going on?")

    // Seen idle in between, say by the event stream, then blocked again.
    let acme = try await Fixtures.client(FakeRunner(snapshot: FocusTests.snapshotWithAcmeIdle)).agents()
    _ = await watcher.observe(acme, after: nil)
    let before = runner.reads.count
    _ = try await session.ask("anything new?")

    #expect(runner.reads.dropFirst(before).contains("w2:p1"))
    #expect(gateway.lastUserRequest.contains("- w2:p1 (acme / tests): blocked → idle by "))
    #expect(gateway.lastUserRequest.contains("; idle → blocked by "))
  }

  @Test func aWorkingAgentShowsWhatsNewOnItsScreen() async throws {
    let runner = FakeRunner(snapshot: Self.snapshotWithDemoWorking, readOutput: "Reading the parser\n❯ \n")
    let gateway = Self.answers(3)
    let session = session(gateway, runner, watcher: watcher(runner))
    _ = try await session.ask("what's going on?")

    runner.readOutput = "Reading the parser\nFixed the tokenizer\n❯ \n"
    _ = try await session.ask("what's new?")
    var request = gateway.lastUserRequest
    #expect(request.contains("- w1:p1 (demo / main): still working; new on its screen:\n    Fixed the tokenizer\n</changes>"))
    // A follow-up about nothing in particular doesn't send its whole screen again.
    #expect(!request.contains(#"<pane id="w1:p1""#))

    _ = try await session.ask("and now?")
    request = gateway.lastUserRequest
    #expect(request.contains("- w1:p1 (demo / main): still working, nothing new on its screen"))
  }

  @Test func aFailedRequestLeavesTheLastOneAsTheStart() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Fixtures.answer("Fine."), Fixtures.answer("Fine.")], failing: [2])
    let session = session(gateway, runner, watcher: watcher(runner))
    _ = try await session.ask("what's going on?")

    runner.snapshot = FocusTests.snapshotWithAcmeIdle
    await #expect(throws: GatewayError.self) { try await session.ask("what changed?") }
    _ = try await session.ask("what changed?")
    #expect(gateway.lastUserRequest.contains("- w2:p1 (acme / tests): blocked → idle by "))
  }

  @Test func aRelaunchCarriesOnFromTheLastRequest() async throws {
    let file = try HerdrWatcherTests.file()
    let runner = FakeRunner()
    _ = try await session(Self.answers(1), runner, watcher: watcher(runner, file: file)).ask("what's going on?")

    // Holler relaunches: a fresh session and watcher, with the same file.
    date.advance(minutes: 9)
    runner.snapshot = FocusTests.snapshotWithAcmeIdle
    let gateway = Self.answers(1)
    _ = try await session(gateway, runner, watcher: watcher(runner, file: file)).ask("what's changed since I last asked?")
    let request = gateway.lastUserRequest
    #expect(request.contains(#"ago="9 min">"#))
    #expect(request.contains("- w2:p1 (acme / tests): blocked → idle by "))
    #expect(request.contains("- w1:p1 · claude · idle, stopped working at least 9 min ago"))
  }

  @Test func withoutAWatcherRequestsAreAsBefore() async throws {
    let (runner, gateway) = (FakeRunner(), Self.answers(2))
    let session = session(gateway, runner, watcher: nil)
    _ = try await session.ask("what's going on?")
    runner.snapshot = FocusTests.snapshotWithAcmeIdle
    let turn = try await session.ask("what changed?")

    #expect(!gateway.lastUserRequest.contains("<changes"))
    #expect(!gateway.lastUserRequest.contains("stopped working"))
    #expect(turn.eventsLive == nil)
  }

  @Test func timesAreWrittenForReading() {
    let start = Date(timeIntervalSince1970: 0)
    #expect(AssistantPrompt.elapsed(from: start, to: start + 59) == "under a minute")
    #expect(AssistantPrompt.elapsed(from: start, to: start + 12 * 60 + 30) == "12 min")
    #expect(AssistantPrompt.elapsed(from: start, to: start + 2 * 3600) == "2 h")
    #expect(AssistantPrompt.elapsed(from: start, to: start + 3900) == "1 h 5 min")
  }

  @Test func agentsThatAppearOrCloseAreNamed() {
    let at = Date(timeIntervalSince1970: 0)
    let changes = AssistantPrompt.Changes(
      since: at,
      list: [
        .init(paneId: "w1:p9", name: "demo / new", from: nil, to: "working", at: at + 60, exact: true),
        .init(paneId: "w1:p4", name: "demo / old", from: "idle", to: nil, at: at + 120, exact: false),
      ], progress: [:])
    let text = AssistantPrompt.changeList(changes, agents: [], now: at + 180)
    #expect(text.contains("- w1:p9 (demo / new): appeared, working, at "))
    #expect(text.contains("- w1:p4 (demo / old): closed by "))
    #expect(text.hasSuffix("</changes>"))
    #expect(
      AssistantPrompt.changeList(.init(since: at, list: [], progress: [:]), agents: [], now: at).contains("(nothing changed)"))
  }

  @Test func newLinesAreTheOnesNotOnTheEarlierScreen() {
    let earlier = "Step 1 done\n✻ Working… (12s)\n❯ "
    let screen = "Step 1 done\nStep 2 done\n✻ Working… (40s)\n❯ "
    #expect(PaneText.newLines(since: earlier, in: screen) == ["Step 2 done", "✻ Working… (40s)"])
    #expect(PaneText.newLines(since: screen, in: screen) == [])
    let long = (1...50).map { "line \($0) of output" }.joined(separator: "\n")
    let kept = PaneText.newLines(since: "", in: long, maxCharacters: 100)
    #expect(kept.first == "…" && kept.last == "line 50 of output")
  }
}
