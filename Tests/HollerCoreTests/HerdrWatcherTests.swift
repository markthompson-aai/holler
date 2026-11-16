import Foundation
import Testing

@testable import HollerCore

/// An event stream the test drives: each subscription is recorded, and
/// events go to the newest one.
final class FakeEventSource: HerdrEventSource, @unchecked Sendable {
  typealias Continuation = AsyncThrowingStream<HerdrEvent, any Error>.Continuation

  private let lock = NSLock()
  private var _subscriptions: [(panes: [String], continuation: Continuation)] = []
  /// When set, every subscription fails straight away.
  var failure: (any Error)?

  var subscriptions: [[String]] { lock.withLock { _subscriptions.map(\.panes) } }

  func subscribe(panes: [String]) -> AsyncThrowingStream<HerdrEvent, any Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: HerdrEvent.self, throwing: (any Error).self)
    if let failure {
      continuation.finish(throwing: failure)
    } else {
      lock.withLock { _subscriptions.append((panes, continuation)) }
    }
    return stream
  }

  func send(_ event: HerdrEvent) {
    _ = lock.withLock { _subscriptions.last }?.continuation.yield(event)
  }

  /// Herdr hangs up.
  func drop() {
    lock.withLock { _subscriptions.last }?.continuation.finish()
  }
}

/// Wall-clock time that only moves when a test moves it.
final class TestDate: @unchecked Sendable {
  private let lock = NSLock()
  private var _now = Date(timeIntervalSince1970: 1_800_000_000)

  var now: Date { lock.withLock { _now } }
  func advance(minutes: Double) { lock.withLock { _now += minutes * 60 } }
}

/// Polls until `condition` holds, failing the test after about two seconds.
func eventually(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
  for _ in 0..<400 {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("condition never held", sourceLocation: sourceLocation)
}

@Suite struct HerdrWatcherTests {
  let date = TestDate()

  func watcher(_ runner: FakeRunner = FakeRunner(), source: FakeEventSource?, file: URL? = nil) -> HerdrWatcher {
    let date = date
    return HerdrWatcher(
      herdr: Fixtures.client(runner), source: source, file: file, now: { date.now }, retryDelays: [.milliseconds(10)],
      settle: .milliseconds(1))
  }

  static func agent(
    _ paneId: String, _ status: String, workspace: String = "demo", tab: String = "main", terminalId: String? = nil
  ) -> HerdrAgent {
    HerdrAgent(
      paneId: paneId, kind: "claude", status: status, workspace: workspace, tab: tab, terminalId: terminalId, cwd: "/tmp",
      title: "", focused: false)
  }

  /// A file to keep the history in, in a fresh folder.
  static func file() throws -> URL {
    try Fixtures.folder("support").appendingPathComponent("herdr-history.json")
  }

  /// Starts `watcher` and waits until its first subscription is live.
  func live(_ watcher: HerdrWatcher, _ source: FakeEventSource) async {
    await watcher.start()
    await eventually { source.subscriptions.count == 1 }
    source.send(.subscribed)
    await eventually { await watcher.isLive }
  }

  @Test func itSubscribesToTheAgentsTheFilterAllows() async {
    let source = FakeEventSource()
    let watcher = HerdrWatcher(herdr: Fixtures.client(FakeRunner(), workspaces: ["demo"]), source: source)
    await watcher.start()
    await eventually { source.subscriptions.count == 1 }
    #expect(source.subscriptions == [["w1:p1"]])
    await watcher.stop()
  }

  @Test func eventsAreTimedWhenTheyHappen() async {
    let source = FakeEventSource()
    let watcher = watcher(source: source)
    await live(watcher, source)
    let start = await watcher.observe([Self.agent("w1:p1", "idle"), Self.agent("w2:p1", "blocked")], after: nil)
    // Already idle when watching began, so only known to be so by now.
    #expect(start.since["w1:p1"] == .init(date: date.now, exact: false))

    date.advance(minutes: 5)
    source.send(.statusChanged(paneId: "w1:p1", status: "working"))
    await eventually { await watcher.watching("w1:p1")?.status == "working" }
    let workingFrom = date.now
    date.advance(minutes: 7)
    let picture = await watcher.observe([Self.agent("w1:p1", "working"), Self.agent("w2:p1", "blocked")], after: start.mark)

    #expect(picture.isLive)
    #expect(picture.since["w1:p1"] == .init(date: workingFrom, exact: true))
    #expect(
      picture.changes == [
        .init(paneId: "w1:p1", name: "demo / main", from: "idle", to: "working", at: workingFrom, exact: true)
      ])
    // Changes already asked about aren't new any more.
    #expect(await watcher.observe([Self.agent("w1:p1", "working"), Self.agent("w2:p1", "blocked")], after: picture.mark).changes == [])
    await watcher.stop()
  }

  @Test func movingBetweenStatusesThatArentWorkingKeepsTheWait() async {
    let watcher = watcher(source: nil)
    _ = await watcher.observe([Self.agent("w1:p1", "working")], after: nil)
    date.advance(minutes: 2)
    let stopped = date.now
    _ = await watcher.observe([Self.agent("w1:p1", "done")], after: nil)
    date.advance(minutes: 10)
    // You looked at it, so Herdr marks it idle; it has still waited since it finished.
    let picture = await watcher.observe([Self.agent("w1:p1", "idle")], after: nil)
    #expect(picture.since["w1:p1"] == .init(date: stopped, exact: false))
  }

  @Test func snapshotsCatchUpOnAgentsThatAppearOrClose() async {
    let watcher = watcher(source: nil)
    let start = await watcher.observe([Self.agent("w1:p1", "idle")], after: nil)
    date.advance(minutes: 3)
    let picture = await watcher.observe([Self.agent("w1:p2", "working", tab: "docs")], after: start.mark)
    #expect(
      picture.changes == [
        .init(paneId: "w1:p2", name: "demo / docs", from: nil, to: "working", at: date.now, exact: false),
        .init(paneId: "w1:p1", name: "demo / main", from: "idle", to: nil, at: date.now, exact: false),
      ])
    #expect(!picture.isLive)
  }

  @Test func aDroppedStreamFallsBackToSnapshotsAndReconnects() async {
    let source = FakeEventSource()
    let watcher = watcher(source: source)
    await live(watcher, source)
    let start = await watcher.observe([Self.agent("w1:p1", "idle"), Self.agent("w2:p1", "blocked")], after: nil)

    source.drop()
    await eventually { await !watcher.isLive }
    date.advance(minutes: 4)
    // Missed by the stream, so timed when a request's snapshot noticed it.
    let picture = await watcher.observe([Self.agent("w1:p1", "working"), Self.agent("w2:p1", "blocked")], after: start.mark)
    #expect(picture.changes.map(\.exact) == [false])
    #expect(picture.since["w1:p1"] == .init(date: date.now, exact: false))

    await eventually { source.subscriptions.count == 2 }
    source.send(.subscribed)
    await eventually { await watcher.isLive }
    await watcher.stop()
  }

  @Test func aStreamThatNeverStartsLeavesSnapshotsWorking() async throws {
    let source = FakeEventSource()
    source.failure = HerdrError.commandFailed(command: "events subscribe", detail: "connect: No such file or directory")
    let watcher = watcher(source: source)
    await watcher.start()
    try await Task.sleep(for: .milliseconds(50))
    let start = await watcher.observe([Self.agent("w1:p1", "working")], after: nil)
    date.advance(minutes: 1)
    let picture = await watcher.observe([Self.agent("w1:p1", "idle")], after: start.mark)
    #expect(!picture.isLive)
    #expect(picture.changes.map(\.to) == ["idle"])
    await watcher.stop()
  }

  @Test func aNewAgentIsSubscribedTo() async {
    let runner = FakeRunner()
    let source = FakeEventSource()
    let watcher = watcher(runner, source: source)
    await live(watcher, source)
    #expect(source.subscriptions == [["w1:p1", "w2:p1"]])

    runner.snapshot = FocusTests.snapshotWithNewAgent
    source.send(.agentsChanged)
    await eventually { source.subscriptions.count == 2 }
    #expect(source.subscriptions.last == ["w1:p2", "w1:p1", "w2:p1"])
    source.send(.subscribed)
    await eventually { await watcher.watching("w1:p2") != nil }
    date.advance(minutes: 1)
    source.send(.statusChanged(paneId: "w1:p2", status: "idle"))
    await eventually { await watcher.watching("w1:p2")?.status == "idle" }
    #expect(await watcher.watching("w1:p2")?.since == .init(date: date.now, exact: true))
    await watcher.stop()
  }

  // MARK: - Agents that need you

  @Test func theCountOfAgentsThatNeedYouFollowsEventsAndSnapshots() async {
    let source = FakeEventSource()
    let watcher = watcher(source: source)
    let counts = Collected(await watcher.needsYouCounts())
    await eventually { counts.values == [0] }

    // Going live looks at Herdr: the fixture's acme agent is blocked, before any request.
    await live(watcher, source)
    await eventually { counts.values == [0, 1] }
    #expect(await watcher.needsYouCount == 1)

    source.send(.statusChanged(paneId: "w1:p1", status: "blocked"))
    await eventually { counts.values == [0, 1, 2] }
    source.send(.statusChanged(paneId: "w2:p1", status: "working"))
    await eventually { counts.values == [0, 1, 2, 1] }
    // Answered in its terminal while the stream was down, so a request's snapshot noticed.
    _ = await watcher.observe([Self.agent("w1:p1", "working"), Self.agent("w2:p1", "working")], after: nil)
    await eventually { counts.values == [0, 1, 2, 1, 0] }
    // A look that changes nothing says nothing.
    _ = await watcher.observe([Self.agent("w1:p1", "idle"), Self.agent("w2:p1", "working")], after: nil)
    #expect(await watcher.needsYouCount == 0)
    #expect(counts.values == [0, 1, 2, 1, 0])
    await watcher.stop()
  }

  @Test func agentsOutsideTheFilterAreNotCounted() async {
    let source = FakeEventSource()
    let date = date
    let watcher = HerdrWatcher(
      herdr: Fixtures.client(FakeRunner(), workspaces: ["demo"]), source: source, now: { date.now },
      retryDelays: [.milliseconds(10)], settle: .milliseconds(1))
    await live(watcher, source)
    // The fixture's blocked agent is in acme, which the filter hides.
    #expect(await watcher.needsYouCount == 0)
    let picture = await watcher.observe(
      [Self.agent("w1:p1", "blocked"), Self.agent("w2:p1", "blocked", workspace: "acme")], after: nil)
    #expect(await watcher.needsYouCount == 1)
    #expect(picture.since.keys.sorted() == ["w1:p1"])
    await watcher.stop()
  }

  @Test func aRelaunchedWatcherKnowsWhoNeedsYouBeforeItLooks() async throws {
    let file = try Self.file()
    _ = await watcher(source: nil, file: file).observe(
      [Self.agent("w1:p1", "blocked"), Self.agent("w2:p1", "done")], after: nil)
    let after = watcher(source: nil, file: file)
    #expect(await after.needsYouCount == 1)
    let counts = Collected(await after.needsYouCounts())
    await eventually { counts.values == [1] }
  }

  // MARK: - History across relaunches

  @Test func aRelaunchedWatcherCarriesOnFromTheSavedHistory() async throws {
    let file = try Self.file()
    let before = watcher(source: nil, file: file)
    let first = await before.observe([Self.agent("w1:p1", "idle"), Self.agent("w2:p1", "working")], after: nil)
    await before.asked(first.mark)
    date.advance(minutes: 5)
    let changed = date.now
    _ = await before.observe([Self.agent("w1:p1", "working"), Self.agent("w2:p1", "working")], after: first.mark)

    // Holler relaunches.
    date.advance(minutes: 7)
    let after = watcher(source: nil, file: file)
    #expect(await after.lastAsked == first.mark)
    let agents = [Self.agent("w1:p1", "working"), Self.agent("w2:p1", "working")]
    let picture = await after.observe(agents, after: await after.lastAsked)
    #expect(
      picture.changes == [
        .init(paneId: "w1:p1", name: "demo / main", from: "idle", to: "working", at: changed, exact: false)
      ])
    #expect(picture.since["w1:p1"] == .init(date: changed, exact: false))
    #expect(picture.since["w2:p1"] == .init(date: first.mark.date, exact: false))
    // The new mark follows on from the saved history, so nothing is listed twice.
    #expect(await after.observe(agents, after: picture.mark).changes == [])
  }

  @Test func agentsThatCloseOrAppearWhileHollerIsOffAreChanges() async throws {
    let file = try Self.file()
    let before = watcher(source: nil, file: file)
    let first = await before.observe([Self.agent("w1:p1", "idle")], after: nil)
    await before.asked(first.mark)

    date.advance(minutes: 3)
    let after = watcher(source: nil, file: file)
    let picture = await after.observe([Self.agent("w1:p2", "working", tab: "docs")], after: await after.lastAsked)
    #expect(
      picture.changes == [
        .init(paneId: "w1:p2", name: "demo / docs", from: nil, to: "working", at: date.now, exact: false),
        .init(paneId: "w1:p1", name: "demo / main", from: "idle", to: nil, at: date.now, exact: false),
      ])
  }

  @Test func aMissingOrCorruptFileStartsEmpty() async throws {
    let file = try Self.file()
    let missing = watcher(source: nil, file: file)
    #expect(await missing.lastAsked == nil)
    #expect(await missing.observe([Self.agent("w1:p1", "idle")], after: nil).changes == [])

    try Data("not json".utf8).write(to: file)
    let corrupt = watcher(source: nil, file: file)
    #expect(await corrupt.lastAsked == nil)
    #expect(await corrupt.watching("w1:p1") == nil)
    // The first look seeds the history, as on a first launch, and replaces the file.
    let first = await corrupt.observe([Self.agent("w1:p1", "idle")], after: nil)
    #expect(first.changes == [])
    await corrupt.asked(first.mark)
    #expect(await watcher(source: nil, file: file).lastAsked == first.mark)
  }

  @Test func theFileKeepsTheLastFiveHundredChanges() async throws {
    let file = try Self.file()
    let before = watcher(source: nil, file: file)
    let first = await before.observe([Self.agent("w1:p1", "idle")], after: nil)
    for round in 1...600 {
      date.advance(minutes: 1)
      _ = await before.observe([Self.agent("w1:p1", round.isMultiple(of: 2) ? "idle" : "working")], after: nil)
    }
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    #expect((saved?["changes"] as? [Any])?.count == 500)

    let after = watcher(source: nil, file: file)
    let picture = await after.observe([Self.agent("w1:p1", "idle")], after: first.mark)
    #expect(picture.changes.count == 500)
    // The oldest 100 are forgotten; round 101 turned it working.
    #expect(picture.changes.first?.to == "working")
    #expect(picture.changes.first?.at == first.mark.date + 101 * 60)
    #expect(picture.changes.last?.to == "idle")
  }

  @Test func aHerdrRestartGivesAPaneIdToANewAgent() async throws {
    let file = try Self.file()
    let before = watcher(source: nil, file: file)
    let first = await before.observe([Self.agent("w1:p1", "working", terminalId: "t-old")], after: nil)
    await before.asked(first.mark)

    // Herdr restarts, and its first pane gets the same id, with a new terminal.
    date.advance(minutes: 10)
    let after = watcher(source: nil, file: file)
    let restarted = [Self.agent("w1:p1", "idle", tab: "fresh", terminalId: "t-new")]
    let picture = await after.observe(restarted, after: await after.lastAsked)
    #expect(
      picture.changes == [
        .init(paneId: "w1:p1", name: "demo / main", from: "working", to: nil, at: date.now, exact: false),
        .init(paneId: "w1:p1", name: "demo / fresh", from: nil, to: "idle", at: date.now, exact: false),
      ])
    // The new agent has only just been seen, not waiting since the old one started.
    #expect(picture.since["w1:p1"] == .init(date: date.now, exact: false))
    #expect(await after.watching("w1:p1")?.status == "idle")
  }

  @Test func aPaneWithoutATerminalIdIsTakenToBeTheSame() async throws {
    let file = try Self.file()
    let before = watcher(source: nil, file: file)
    let first = await before.observe([Self.agent("w1:p1", "idle")], after: nil)
    await before.asked(first.mark)

    // An older Herdr gave no terminal id; a newer one does. Nothing says the pane changed.
    date.advance(minutes: 2)
    let after = watcher(source: nil, file: file)
    let picture = await after.observe([Self.agent("w1:p1", "idle", terminalId: "t-1")], after: await after.lastAsked)
    #expect(picture.changes == [])
    #expect(picture.since["w1:p1"] == .init(date: first.mark.date, exact: false))
  }
}
