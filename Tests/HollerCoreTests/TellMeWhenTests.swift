import Foundation
import Testing

@testable import HollerCore

/// "Tell me when the api agent finishes": an alert the session keeps until
/// the agent stops working, then a quiet note.
@Suite struct TellMeWhenTests {
  let date = TestDate()

  func watcher(_ runner: FakeRunner, source: FakeEventSource? = nil) -> HerdrWatcher {
    let date = date
    return HerdrWatcher(
      herdr: Fixtures.client(runner), source: source, now: { date.now }, retryDelays: [.milliseconds(10)],
      settle: .milliseconds(1))
  }

  @Test func theWatcherTellsItsFollowersOfEachChange() async {
    let (runner, source) = (FakeRunner(), FakeEventSource())
    let watcher = watcher(runner, source: source)
    let changes = Collected(await watcher.changes())
    await watcher.start()
    await eventually { source.subscriptions.count == 1 }
    source.send(.subscribed)
    await eventually { await watcher.isLive }

    source.send(.statusChanged(paneId: "w1:p1", status: "working"))
    await eventually { changes.values.count == 1 }
    #expect(changes.values == [.init(paneId: "w1:p1", name: "demo / main", from: "idle", to: "working", at: date.now, exact: true)])

    // A snapshot that finds a difference the stream didn't report counts too.
    runner.snapshot = Fixtures.snapshotWithoutDemoAgent
    _ = await watcher.observe(try! await Fixtures.client(runner).agents(), after: nil)
    await eventually { changes.values.count == 3 }
    #expect(changes.values.dropFirst().map(\.paneId).sorted() == ["w1:p1", "w1:p7"])
    #expect(changes.values.first { $0.paneId == "w1:p1" && $0.to == nil }?.exact == false)
    await watcher.stop()
  }

  func session(_ gateway: FakeGateway, _ runner: FakeRunner, watcher: HerdrWatcher?) -> AssistantSession {
    AssistantSession(
      gateway: gateway, herdr: Fixtures.client(runner), watcher: watcher,
      configuration: .init(model: "test-model", prefetchLines: 0))
  }

  /// What the tool told the model, in the request after it ran.
  func toolResult(_ gateway: FakeGateway, request: Int = 1) throws -> String {
    try #require(gateway.requests[request].messages.last?.content)
  }

  static let tellMe = Fixtures.toolCall("c1", "tell_me_when", #"{"pane_id":"w1:p1"}"#)

  @Test func theModelSetsAnAlertAndTheNextRequestKnowsOfIt() async throws {
    let runner = FakeRunner(snapshot: WhatChangedTests.snapshotWithDemoWorking)
    let gateway = FakeGateway([Self.tellMe, Fixtures.answer("I'll tell you when the main agent finishes."), Fixtures.answer("Yes.")])
    let session = session(gateway, runner, watcher: watcher(runner))
    let turn = try await session.ask("tell me when the main agent finishes")

    #expect(turn.answer == "I'll tell you when the main agent finishes.")
    #expect(turn.actions.isEmpty && turn.tools.map(\.name) == ["tell_me_when"] && turn.tools.first?.failed == false)
    #expect(try toolResult(gateway) == #"{"status":"will_tell_the_user","alert_id":"t1","agent_status":"working","events":"down"}"#)
    #expect(turn.about == ["w1:p1"])

    _ = try await session.ask("did you set that?")
    #expect(gateway.lastUserRequest.contains("title \"Refactor parser\" · the user asked to be told when it stops working"))
  }

  @Test func anAgentThatIsntWorkingStillGetsAnAlertForTheNextTimeItStops() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.tellMe, Fixtures.answer("It's idle; I'll tell you next time.")])
    _ = try await session(gateway, runner, watcher: watcher(runner)).ask("tell me when main finishes")
    #expect(try toolResult(gateway) == #"{"status":"will_tell_the_user","alert_id":"t1","agent_status":"idle","events":"down"}"#)
  }

  @Test func oneAlertPerAgent() async throws {
    let runner = FakeRunner(snapshot: WhatChangedTests.snapshotWithDemoWorking)
    let gateway = FakeGateway([Self.tellMe, Fixtures.answer("Will do."), Self.tellMe, Fixtures.answer("Already set.")])
    let session = session(gateway, runner, watcher: watcher(runner))
    _ = try await session.ask("tell me when main finishes")
    let turn = try await session.ask("tell me when main finishes")
    #expect(try toolResult(gateway, request: 3).contains("t1 is already set to tell the user when w1:p1 stops working"))
    #expect(turn.tools.first?.failed == true)
  }

  @Test func withoutAWatcherTheToolSaysItCannot() async throws {
    let gateway = FakeGateway([Self.tellMe, Fixtures.answer("Sorry, I can't.")])
    let turn = try await session(gateway, FakeRunner(), watcher: nil).ask("tell me when main finishes")
    #expect(try toolResult(gateway).contains("isn't following Herdr's events"))
    #expect(turn.tools.first?.failed == true)
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

  static let setAlert = Alert(
    id: "t1", paneId: "w1:p1", name: "demo / main", request: "tell me when the main agent finishes")

  @Test func theAlertFiresWhenTheAgentStopsWorking() async throws {
    let (runner, source) = (FakeRunner(snapshot: WhatChangedTests.snapshotWithDemoWorking), FakeEventSource())
    let watcher = await liveWatcher(runner, source)
    let gateway = FakeGateway([Self.tellMe, Fixtures.answer("Will do."), Fixtures.answer("It ran the tests.")])
    let session = session(gateway, runner, watcher: watcher)
    let fired = Collected(await session.alerts())
    _ = try await session.ask(Self.setAlert.request)
    #expect(try toolResult(gateway).hasSuffix(#""events":"live"}"#))

    runner.snapshot = Fixtures.snapshot
    source.send(.statusChanged(paneId: "w1:p1", status: "idle"))
    await eventually { fired.values.count == 1 }
    #expect(fired.values == [.init(alert: Self.setAlert, answer: "**demo / main** has finished.")])

    // The next request hears of it, and the agent, no longer working, is read.
    _ = try await session.ask("what did it do?")
    let request = gateway.lastUserRequest
    #expect(request.contains("<since_last_reply>\nHoller told the user in a note that w1:p1 (demo / main) had finished at "))
    #expect(request.contains(", now idle, as they asked (t1); that alert is done.\n</since_last_reply>"))
    #expect(!request.contains("the user asked to be told"))
    await watcher.stop()
  }

  @Test func anAgentThatStopsNeedingYouOrClosesSaysSo() async throws {
    let (runner, source) = (FakeRunner(snapshot: WhatChangedTests.snapshotWithDemoWorking), FakeEventSource())
    let watcher = await liveWatcher(runner, source)
    let gateway = FakeGateway([
      Self.tellMe, Fixtures.answer("Will do."), Self.tellMe, Fixtures.answer("Will do."),
    ])
    let session = session(gateway, runner, watcher: watcher)
    let fired = Collected(await session.alerts())

    _ = try await session.ask("tell me when main finishes")
    source.send(.statusChanged(paneId: "w1:p1", status: "blocked"))
    await eventually { fired.values.count == 1 }
    #expect(fired.values.last?.answer == "**demo / main** has stopped and needs you.")

    // Set again once it's working again; then its tab closes.
    source.send(.statusChanged(paneId: "w1:p1", status: "working"))
    await eventually { await watcher.watching("w1:p1")?.status == "working" }
    _ = try await session.ask("tell me when main finishes")
    // Its tab closes: Herdr says the agents changed, and the watcher subscribes again.
    runner.snapshot = Fixtures.snapshotWithoutDemoAgent
    source.send(.agentsChanged)
    await eventually { source.subscriptions.count == 2 }
    source.send(.subscribed)
    await eventually { fired.values.count == 2 }
    #expect(fired.values.last?.alert.id == "t2" && fired.values.last?.answer == "**demo / main** has closed.")
    await watcher.stop()
  }

  @Test func anAgentStartingWorkDoesNotFireTheAlert() async throws {
    let (runner, source) = (FakeRunner(), FakeEventSource())
    let watcher = await liveWatcher(runner, source)
    let gateway = FakeGateway([Self.tellMe, Fixtures.answer("Will do.")])
    let session = session(gateway, runner, watcher: watcher)
    let fired = Collected(await session.alerts())
    _ = try await session.ask("tell me when main finishes")

    source.send(.statusChanged(paneId: "w1:p1", status: "working"))
    await eventually { await watcher.watching("w1:p1")?.status == "working" }
    #expect(fired.values.isEmpty)
    source.send(.statusChanged(paneId: "w1:p1", status: "done"))
    await eventually { fired.values.count == 1 }
    #expect(fired.values.last?.answer == "**demo / main** has finished.")
    await watcher.stop()
  }

  @MainActor @Test func anAlertOpensAQuietNoteWithNothingSpoken() async throws {
    let (runner, source) = (FakeRunner(snapshot: WhatChangedTests.snapshotWithDemoWorking), FakeEventSource())
    let watcher = await liveWatcher(runner, source)
    let gateway = FakeGateway([Self.tellMe, Fixtures.answer("Will do.")])
    let (herdr, speaker) = (Fixtures.client(runner), FakeSpeaker())
    let controller = AssistantController(voice: FakeVoice(), speaker: speaker, herdr: herdr) {
      AssistantSession(gateway: gateway, herdr: herdr, watcher: watcher, configuration: .init(model: "test", prefetchLines: 0))
    }
    controller.ask(Self.setAlert.request)
    await controller.settle()
    controller.dismiss()
    #expect(controller.phase == .idle)

    source.send(.statusChanged(paneId: "w1:p1", status: "idle"))
    await settled { controller.phase == .ready }
    #expect(controller.exchanges.map(\.request) == [Self.setAlert.request])
    #expect(controller.exchanges.last?.answer == "**demo / main** has finished." && controller.exchanges.last?.readAloud == false)
    #expect(!controller.holdsKeyboard && !speaker.events.contains { $0.hasPrefix("speak") })
    await watcher.stop()
  }

  @MainActor @Test func anAlertJoinsAnOpenNote() async throws {
    let (runner, source) = (FakeRunner(snapshot: WhatChangedTests.snapshotWithDemoWorking), FakeEventSource())
    let watcher = await liveWatcher(runner, source)
    let gateway = FakeGateway([Self.tellMe, Fixtures.answer("Will do."), Fixtures.answer("Both fine.")])
    let herdr = Fixtures.client(runner)
    let controller = AssistantController(voice: FakeVoice(), herdr: herdr) {
      AssistantSession(gateway: gateway, herdr: herdr, watcher: watcher, configuration: .init(model: "test", prefetchLines: 0))
    }
    controller.ask(Self.setAlert.request)
    await controller.settle()
    controller.ask("and the rest?")
    await controller.settle()

    source.send(.statusChanged(paneId: "w1:p1", status: "idle"))
    await settled { controller.exchanges.count == 3 }
    #expect(controller.phase == .ready)
    #expect(controller.exchanges.map(\.answer) == ["Will do.", "Both fine.", "**demo / main** has finished."])
    #expect(controller.exchanges.last?.request == Self.setAlert.request)
    await watcher.stop()
  }
}

