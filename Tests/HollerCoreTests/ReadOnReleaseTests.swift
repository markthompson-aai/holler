import Foundation
import Testing

@testable import HollerCore

/// Herdr read on releasing the key, while the transcript comes in: the
/// request that follows uses what was read rather than reading again, seen in
/// the commands Herdr receives.
@Suite struct ReadOnReleaseTests {
  func session(_ gateway: FakeGateway, _ runner: FakeRunner, clock: TestClock = TestClock()) -> AssistantSession {
    AssistantSession(
      gateway: gateway, herdr: Fixtures.client(runner), configuration: .init(model: "test-model", prefetchLines: 40),
      clock: clock)
  }

  func snapshots(_ runner: FakeRunner) -> Int {
    runner.calls.filter { $0.starts(with: ["api", "snapshot"]) }.count
  }

  @Test func aRequestUsesWhatWasReadOnRelease() async throws {
    let runner = FakeRunner(readOutput: "Build succeeded\n")
    let gateway = FakeGateway([Fixtures.answer("Both idle.")])
    let session = session(gateway, runner)
    await session.prepare()
    let turn = try await session.ask("summarise")

    #expect(turn.readOnRelease && turn.agentsRead == 2)
    #expect(snapshots(runner) == 1 && runner.reads.count == 2)
    let user = try #require(gateway.requests.first?.messages.last?.content)
    #expect(user.contains("<pane id=\"w1:p1\" status=\"idle\">\nBuild succeeded\n</pane>"))
  }

  @Test func onlyWhatIsOnScreenIsRead() async throws {
    let runner = FakeRunner()
    runner.workingPanes = ["w2:p1"]
    _ = try await session(FakeGateway([Fixtures.answer("ok")]), runner).ask("summarise")

    let reads = runner.calls.filter { $0.starts(with: ["agent", "read"]) }
    #expect(reads.count == 2)
    #expect(reads.allSatisfy { $0.contains("visible") && $0.last == "40" })
  }

  @Test func aReadFromLongBeforeTheRequestIsReadAgain() async throws {
    let clock = TestClock()
    let runner = FakeRunner()
    let session = session(FakeGateway([Fixtures.answer("ok")]), runner, clock: clock)
    await session.prepare()
    clock.advance(by: .seconds(11))
    let turn = try await session.ask("summarise")

    #expect(!turn.readOnRelease)
    #expect(snapshots(runner) == 2)
  }

  @Test func aReadForTheLastConversationIsReadAgain() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Fixtures.answer("Demo is idle.<about>w1:p1</about>"), Fixtures.answer("Both idle.")])
    let session = session(gateway, runner)
    _ = try await session.ask("how's demo?")
    // Read as a follow-up, so only demo's screen.
    await session.prepare()
    await session.newConversation()
    let turn = try await session.ask("what's everyone doing?")

    #expect(!turn.readOnRelease && turn.agentsRead == 2)
  }
}
