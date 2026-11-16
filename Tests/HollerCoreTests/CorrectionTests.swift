import Foundation
import Testing

@testable import HollerCore

/// Replays a script like `FakeGateway`, but holds one request until the test
/// lets it go, so the test can act while the turn is under way.
final class GatedGateway: ChatCompleting, @unchecked Sendable {
  let script: FakeGateway
  private let held: Int
  private let (reached, reachedSignal) = AsyncStream.makeStream(of: Void.self)
  private let (released, releaseSignal) = AsyncStream.makeStream(of: Void.self)
  private let lock = NSLock()
  private var calls = 0

  /// Holds the `held`th request, counting from 1.
  init(_ script: [ChatMessage], holding held: Int) {
    self.script = FakeGateway(script)
    self.held = held
  }

  func complete(_ request: ChatRequest) async throws -> ChatCompletion {
    let call = lock.withLock {
      calls += 1
      return calls
    }
    if call == held {
      reachedSignal.yield()
      for await _ in released { break }
    }
    return try await script.complete(request)
  }

  /// Waits until the held request has been made.
  func waitUntilHeld() async {
    for await _ in reached { break }
  }

  func release() { releaseSignal.yield() }
}

/// A correction ("actually, say this instead") replaces the card it corrects,
/// rather than leaving both waiting; an addition ("and also tell it…") doesn't.
@Suite struct CorrectionTests {
  func session(_ gateway: any ChatCompleting, _ client: HerdrClient) -> AssistantSession {
    AssistantSession(gateway: gateway, herdr: client, configuration: .init(model: "test-model", prefetchLines: 0))
  }

  static let send = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#)
  static let correction = Fixtures.toolCall(
    "c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"stop instead","replaces":"a1"}"#)

  @Test func everyActionToolOffersReplaces() {
    for name in ["prompt_agent", "start_agent", "close_tab", "interrupt_agent"] {
      let parameters = AssistantTools.named(name)?.definition.function.parameters
      #expect(parameters?["properties"]?["replaces"] != nil, "\(name)")
      guard case .array(let required) = parameters?["required"] else {
        Issue.record("\(name) has no required list")
        continue
      }
      #expect(!required.contains("replaces"), "\(name)")
    }
  }

  @Test func aCorrectionReplacesTheWaitingCard() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.send, Self.correction, Fixtures.answer("Okay.")])
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("tell demo to carry on")
    let events = Events()

    let turn = try await session.ask("actually, tell it to stop instead") { events.append($0) }
    #expect(turn.actions.map(\.id) == ["a2"] && turn.replaced == ["a1"])
    #expect(events.statuses(of: "a1") == [.replaced])
    #expect(gateway.requests.count == 2)

    // The replaced card can't be sent any more; its correction can.
    #expect(try await session.confirm("a1") == nil)
    try await session.confirm("a2")
    #expect(runner.writes == [["agent", "prompt", "w1:p1", "stop instead"]])
    _ = try await session.ask("did it go?")
    let followUp = try #require(gateway.requests.last?.messages.last?.content)
    #expect(followUp.contains("a1 was dropped because a2 replaced it as a correction; nothing was done."))
  }

  @Test func anAdditionLeavesTheEarlierCardWaiting() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([
      Self.send, Fixtures.toolCall("c2", "prompt_agent", #"{"pane_id":"w1:p1","message":"and run the tests"}"#),
    ])
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("tell demo to carry on")
    let events = Events()

    let turn = try await session.ask("and also tell it to run the tests") { events.append($0) }
    #expect(turn.actions.map(\.id) == ["a2"] && turn.replaced.isEmpty)
    #expect(events.statuses(of: "a1").isEmpty)
    try await session.confirm("a1")
    try await session.confirm("a2")
    #expect(runner.writes.count == 2)
  }

  @Test func replacingACardThatIsNotWaitingQueuesNothingAndTellsTheModel() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.send, Self.correction, Fixtures.answer("It was already sent.")])
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("tell demo to carry on")
    try await session.confirm("a1")

    let turn = try await session.ask("actually, tell it to stop instead")
    #expect(turn.actions.isEmpty && turn.replaced.isEmpty)
    #expect(turn.answer == "It was already sent.")
    let result = try #require(gateway.requests.last?.messages.last?.content)
    #expect(result.contains("a1 is not a card still waiting"))
  }

  @Test func aFailedRequestReplacesNothing() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway(
      [
        Self.send,
        ChatMessage(
          role: .assistant, content: nil,
          toolCalls: [
            ToolCall(id: "c2", name: "prompt_agent", arguments: #"{"pane_id":"w1:p1","message":"stop","replaces":"a1"}"#),
            ToolCall(id: "c3", name: "list_agents", arguments: "{}"),
          ]),
      ], failing: [3])
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("tell demo to carry on")
    let events = Events()

    await #expect(throws: FakeGateway.failure) { try await session.ask("actually, tell it to stop") { events.append($0) } }
    #expect(events.statuses(of: "a1").isEmpty && events.statuses(of: "a2") == [.withdrawn])
    try await session.confirm("a1")
    #expect(runner.writes == [["agent", "prompt", "w1:p1", "carry on"]])
  }

  @Test func aCardConfirmedWhileItsCorrectionIsUnderWayIsLeftAlone() async throws {
    let runner = FakeRunner()
    let gateway = GatedGateway(
      [
        Self.send,
        ChatMessage(
          role: .assistant, content: nil,
          toolCalls: [
            ToolCall(id: "c2", name: "prompt_agent", arguments: #"{"pane_id":"w1:p1","message":"stop","replaces":"a1"}"#),
            ToolCall(id: "c3", name: "list_agents", arguments: "{}"),
          ]),
        Fixtures.answer("Ready to send."),
        Fixtures.answer("Both are there."),
      ], holding: 3)
    let session = session(gateway, Fixtures.client(runner))
    _ = try await session.ask("tell demo to carry on")

    async let correcting = session.ask("actually, tell it to stop")
    await gateway.waitUntilHeld()
    try await session.confirm("a1")
    gateway.release()
    let turn = try await correcting

    #expect(turn.actions.map(\.id) == ["a2"] && turn.replaced.isEmpty)
    #expect(runner.writes == [["agent", "prompt", "w1:p1", "carry on"]])
    _ = try await session.ask("what's waiting?")
    let followUp = try #require(gateway.script.requests.last?.messages.last?.content)
    #expect(followUp.contains("a2 was meant to replace a1, but the user had already answered a1; a2 waits on its own."))
  }
}
