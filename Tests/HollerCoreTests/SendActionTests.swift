import Foundation
import Testing

@testable import HollerCore

/// The send action, through the session: the card it queues and the agents
/// it refuses. Its lifecycle and notes are in `ActionStatusTests`.
@Suite struct SendActionTests {
  func session(_ gateway: FakeGateway, _ runner: FakeRunner = FakeRunner()) -> AssistantSession {
    AssistantSession(gateway: gateway, herdr: Fixtures.client(runner), configuration: .init(model: "test-model", prefetchLines: 0))
  }

  static let send = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#)

  @Test func aQueuedSendCarriesItsCard() async throws {
    let runner = FakeRunner()
    let events = Events()
    _ = try await session(FakeGateway([Self.send]), runner).ask("tell demo to carry on") {
      events.append($0)
    }

    #expect(
      events.queued.map(\.card) == [
        ConfirmCard(
          kind: .send, verb: "Send to", target: "demo / main", body: "carry on",
          words: .init(
            button: "Send", busy: "Sending…", done: "Sent", cancelled: "Cancelled. Nothing was sent.", failed: "Not sent",
            countdown: "Sending in", runNow: "Send now"))
      ])
    #expect(runner.writes.isEmpty)
  }

  @Test func aBlockedAgentIsRefused() async throws {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w2:p1","message":"go"}"#),
      Fixtures.answer("acme is waiting for approval."),
    ])
    let events = Events()
    let turn = try await session(gateway).ask("tell acme to go") { events.append($0) }

    #expect(turn.actions.isEmpty)
    #expect(events.queued.isEmpty)
    let result = try #require(gateway.requests.last?.messages.last?.content)
    #expect(result == #"{"error":"w2:p1 is blocked waiting for approval in its terminal; it can't take a message"}"#)
  }
}
