import Foundation
import Testing

@testable import HollerCore

/// The agent list: the rows the note shows the moment you let go of the key,
/// from the snapshot the request starts from, until the answer replaces them.
@Suite struct AgentListTests {
  let date = TestDate()

  func watcher(_ runner: FakeRunner, source: FakeEventSource? = nil) -> HerdrWatcher {
    let date = date
    return HerdrWatcher(
      herdr: Fixtures.client(runner), source: source, now: { date.now }, retryDelays: [.milliseconds(10)],
      settle: .milliseconds(1))
  }

  func session(_ gateway: FakeGateway, _ runner: FakeRunner, watcher: HerdrWatcher?) -> AssistantSession {
    AssistantSession(
      gateway: gateway, herdr: Fixtures.client(runner), watcher: watcher,
      configuration: .init(model: "test-model", prefetchLines: 0))
  }

  @Test func releasingTheKeyListsEveryAgentWhatNeedsYouFirst() async throws {
    let runner = FakeRunner()
    let session = session(FakeGateway([Fixtures.answer("Fine.")]), runner, watcher: nil)
    let lists = Collected(await session.agentLists())

    await session.prepare()
    await eventually { lists.values.count == 1 }
    #expect(
      lists.values.first == [
        AgentRow(name: "acme / tests", state: .needsYou, update: ""),
        AgentRow(name: "demo / main", state: .idle, update: ""),
      ])
  }

  @Test func aRequestNothingWasReadForOnReleaseListsThemItself() async throws {
    let runner = FakeRunner()
    let session = session(FakeGateway([Fixtures.answer("Fine.")]), runner, watcher: nil)
    let lists = Collected(await session.agentLists())

    _ = try await session.ask("what's everyone doing?")
    await eventually { lists.values.count == 1 }
    #expect(lists.values.first?.map(\.name) == ["acme / tests", "demo / main"])
  }

  @Test func rowsSayHowLongEachAgentHasBeenSo() async throws {
    let runner = FakeRunner()
    let watcher = watcher(runner)
    let session = session(FakeGateway([Fixtures.answer("Fine."), Fixtures.answer("Fine.")]), runner, watcher: watcher)
    let lists = Collected(await session.agentLists())

    // Just seen, already so: nothing is known yet about for how long.
    _ = try await session.ask("what's going on?")
    await eventually { lists.values.count == 1 }
    #expect(lists.values.last?.map(\.update) == ["", ""])

    date.advance(minutes: 12)
    await session.prepare()
    await eventually { lists.values.count == 2 }
    #expect(
      lists.values.last == [
        AgentRow(name: "acme / tests", state: .needsYou, update: "Waiting at least 12 min."),
        AgentRow(name: "demo / main", state: .idle, update: "Stopped at least 12 min ago."),
      ])
  }

  /// A watcher following `source`, live.
  func liveWatcher(_ runner: FakeRunner, _ source: FakeEventSource) async -> HerdrWatcher {
    let watcher = watcher(runner, source: source)
    await watcher.start()
    await eventually { source.subscriptions.count == 1 }
    source.send(.subscribed)
    await eventually { await watcher.isLive }
    return watcher
  }

  @Test func aRowFlipsInPlaceWhenItsAgentChangesWhileTheListStands() async throws {
    let (runner, source) = (FakeRunner(), FakeEventSource())
    let watcher = await liveWatcher(runner, source)
    let session = session(FakeGateway([Fixtures.answer("Fine.")]), runner, watcher: watcher)
    let lists = Collected(await session.agentLists())
    await session.prepare()
    await eventually { lists.values.count == 1 }

    runner.snapshot = Fixtures.snapshot(demoAgent: "working")
    source.send(.statusChanged(paneId: "w1:p1", status: "working"))
    await eventually { lists.values.count == 2 }
    #expect(
      lists.values.last == [
        AgentRow(name: "acme / tests", state: .needsYou, update: ""),
        AgentRow(name: "demo / main", state: .working, update: "Working for under a minute."),
      ])

    date.advance(minutes: 5)
    source.send(.statusChanged(paneId: "w1:p1", status: "blocked"))
    await eventually { lists.values.count == 3 }
    #expect(lists.values.last?.first == AgentRow(name: "demo / main", state: .needsYou, update: "Waiting under a minute."))

    // Answered and gone idle: it has still been waiting since it stopped.
    date.advance(minutes: 2)
    source.send(.statusChanged(paneId: "w1:p1", status: "idle"))
    await eventually { lists.values.count == 4 }
    #expect(lists.values.last?.last == AgentRow(name: "demo / main", state: .idle, update: "Stopped 2 min ago."))
    await watcher.stop()
  }

  @Test func theListEndsWithTheRequest() async throws {
    let (runner, source) = (FakeRunner(), FakeEventSource())
    let watcher = await liveWatcher(runner, source)
    let session = session(FakeGateway([Fixtures.answer("Fine.")]), runner, watcher: watcher)
    let lists = Collected(await session.agentLists())
    _ = try await session.ask("what's going on?")
    await eventually { lists.values.count == 1 }

    source.send(.statusChanged(paneId: "w1:p1", status: "working"))
    await eventually { await watcher.watching("w1:p1")?.status == "working" }
    try await Task.sleep(for: .milliseconds(20))
    #expect(lists.values.count == 1)
    await watcher.stop()
  }

  @Test func anAgentThatClosesDropsOffAndOneThatAppearsJoins() async throws {
    let runner = FakeRunner()
    let watcher = watcher(runner)
    let session = session(FakeGateway([Fixtures.answer("Fine.")]), runner, watcher: watcher)
    let lists = Collected(await session.agentLists())
    await session.prepare()
    await eventually { lists.values.count == 1 }

    // The demo agent's pane has gone and another has it, as a snapshot finds.
    runner.snapshot = Fixtures.snapshotWithoutDemoAgent
    _ = await watcher.observe(try await Fixtures.client(runner).agents(), after: nil)
    await eventually { lists.values.count == 3 }
    #expect(
      lists.values.last == [
        AgentRow(name: "acme / tests", state: .needsYou, update: ""),
        AgentRow(name: "demo / main", state: .idle, update: ""),
      ])
  }

  @MainActor func controller(
    _ gateway: any ChatCompleting, _ runner: FakeRunner, voice: FakeVoice = FakeVoice(), watcher: HerdrWatcher? = nil
  ) -> AssistantController {
    let herdr = Fixtures.client(runner)
    return AssistantController(voice: voice, herdr: herdr, tapThreshold: .zero) {
      AssistantSession(
        gateway: gateway, herdr: herdr, watcher: watcher, configuration: .init(model: "test", prefetchLines: 0))
    }
  }

  /// Waits for the model to be asked, by when Herdr has been read and the
  /// list, if any, is on its way to the note.
  @MainActor func asked(_ gateway: HeldGateway) async throws {
    await settled { gateway.held == 1 }
    try await Task.sleep(for: .milliseconds(20))
  }

  @Test @MainActor func theNoteOpensWithTheListOnReleaseUntilTheAnswerReplacesIt() async throws {
    let gateway = HeldGateway([Fixtures.answer("**demo / main**: idle"), Fixtures.answer("Fine.")])
    let controller = controller(gateway, FakeRunner())
    controller.hotkeyDown()
    controller.hotkeyUp()
    await settled { controller.agentList != nil }
    #expect(controller.form == .note && controller.status != nil)
    #expect(controller.agentList?.map(\.name) == ["acme / tests", "demo / main"])

    gateway.release()
    await controller.settle()
    #expect(controller.agentList == nil && controller.exchanges.last?.answer == "**demo / main**: idle")

    // A follow-up in the open note shows none: the earlier answer is there to read.
    controller.ask("and now?")
    try await asked(gateway)
    #expect(controller.agentList == nil && controller.phase == .thinking)
    gateway.release()
    await controller.settle()
    #expect(controller.exchanges.map(\.answer) == ["**demo / main**: idle", "Fine."])
  }

  @Test @MainActor func aRequestAfterOneThatFailedShowsNoList() async throws {
    let gateway = HeldGateway([Fixtures.answer("Fine.")], failing: [1])
    let controller = controller(gateway, FakeRunner())
    controller.ask("what's everyone doing?")
    gateway.release()
    await controller.settle()
    if case .failed = controller.phase {} else { Issue.record("the request didn't fail") }
    #expect(controller.form == .note)

    // The error is there to read, so the next request doesn't open the note.
    controller.ask("try again")
    try await asked(gateway)
    #expect(controller.agentList == nil && controller.phase == .thinking)
    gateway.release()
    await controller.settle()
  }

  @Test @MainActor func closingTheNoteClearsTheList() async {
    let gateway = HeldGateway([Fixtures.answer("Fine.")])
    let controller = controller(gateway, FakeRunner())
    controller.ask("what's everyone doing?")
    await settled { controller.agentList != nil }
    #expect(controller.form == .note)

    controller.dismiss()
    #expect(controller.agentList == nil && controller.form == .hidden)
    gateway.release()
    await controller.settle()
    #expect(controller.agentList == nil && controller.form == .hidden)
  }

  @Test @MainActor func theLastAgentClosingTakesTheListAway() async throws {
    let runner = FakeRunner()
    let watcher = watcher(runner)
    let gateway = HeldGateway([Fixtures.answer("Nobody's running.")])
    let controller = controller(gateway, runner, watcher: watcher)
    controller.ask("what's everyone doing?")
    await settled { controller.agentList != nil }

    runner.snapshot = Fixtures.snapshot.replacingOccurrences(of: Fixtures.snapshotAgents, with: #""agents":[]"#)
    _ = await watcher.observe(try await Fixtures.client(runner).agents(), after: nil)
    await settled { controller.agentList == nil }
    #expect(controller.form == .pill && controller.phase == .thinking)
    gateway.release()
    await controller.settle()
  }

  @Test @MainActor func aPressThatHearsNothingLeavesTheNoteSayingSo() async throws {
    let voice = FakeVoice(transcript: "")
    voice.startDelay = .milliseconds(50)
    let controller = controller(HeldGateway([]), FakeRunner(), voice: voice)
    controller.hotkeyDown()
    controller.hotkeyUp()
    await settled { controller.agentList != nil }

    await controller.settle()
    #expect(controller.phase == .ready && controller.agentList == nil)
    #expect(controller.form == .note && controller.notice?.hasPrefix("Didn't catch that") == true)
  }
}
