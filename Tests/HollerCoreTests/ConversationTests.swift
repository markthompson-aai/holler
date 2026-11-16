import Foundation
import Testing

@testable import HollerCore

/// What a follow-up carries from earlier exchanges, seen in the requests the
/// model receives.
@Suite struct ConversationTests {
  func session(_ gateway: FakeGateway, _ runner: FakeRunner = FakeRunner(), clock: TestClock = TestClock())
    -> AssistantSession
  {
    AssistantSession(
      gateway: gateway, herdr: Fixtures.client(runner), configuration: .init(model: "test-model", prefetchLines: 40),
      clock: clock)
  }

  static let send = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#)

  /// What the next request carries from earlier exchanges.
  func earlier(_ gateway: FakeGateway) throws -> [String?] {
    try #require(gateway.requests.last?.messages).dropFirst().dropLast().map(\.content)
  }

  @Test func earlierExchangesAreRequestAndAnswerTextOnly() async throws {
    let gateway = FakeGateway([
      Fixtures.toolCall("c1", "read_agents", #"{"pane_ids":["w1:p1"]}"#),
      Fixtures.answer("**demo / main**: idle, tests passed."),
      Fixtures.answer("Nothing new."),
    ])
    let session = session(gateway)
    _ = try await session.ask("how's the demo agent?")
    _ = try await session.ask("anything new?")

    let messages = try #require(gateway.requests.last?.messages)
    #expect(messages.map(\.role) == [.system, .user, .assistant, .user])
    let earlier = try #require(messages[1].content)
    #expect(earlier == "<request>\nhow's the demo agent?\n</request>")
    #expect(messages[2].content == "**demo / main**: idle, tests passed." && messages[2].toolCalls == nil)
    let current = try #require(messages[3].content)
    #expect(current.contains("<agents as_of="))
    #expect(current.contains("<workspaces>"))
    #expect(current.contains("<recent_output>"))
    #expect(current.hasSuffix("<request>\nanything new?\n</request>"))
  }

  @Test func onlyTheLastFiveExchangesAreKept() async throws {
    let gateway = FakeGateway((1...7).map { Fixtures.answer("answer \($0)") })
    let session = session(gateway)
    for n in 1...7 { _ = try await session.ask("request \(n)") }

    let messages = try #require(gateway.requests.last?.messages).dropFirst().dropLast()
    #expect(AssistantSession.Configuration(model: "m").rememberedExchanges == 5)
    #expect(messages.map { $0.content ?? "" } == (2...6).flatMap { ["<request>\nrequest \($0)\n</request>", "answer \($0)"] })
  }

  @Test func aFailedRequestLeavesTheConversationAsItWas() async throws {
    // The second request reads a pane, then its next model call fails.
    let gateway = FakeGateway(
      [
        Fixtures.answer("Both idle."), Fixtures.toolCall("c1", "read_agents", #"{"pane_ids":["w1:p1"]}"#),
        Fixtures.answer("Still idle."),
      ], failing: [3])
    let session = session(gateway)
    _ = try await session.ask("summarise")
    await #expect(throws: FakeGateway.failure) { try await session.ask("this one fails") }
    _ = try await session.ask("and now?")

    let messages = try #require(gateway.requests.last?.messages).dropFirst()
    #expect(messages.map(\.role) == [.user, .assistant, .user])
    #expect(messages.first?.content == "<request>\nsummarise\n</request>")
    #expect(!messages.contains { $0.content?.contains("this one fails") == true })
    #expect(!messages.contains { $0.role == .tool || $0.toolCalls != nil })
  }

  @Test func anEarlierAnswerKeepsItsReadAloudBlockOnlyIfItWasRead() async throws {
    let gateway = FakeGateway([
      Fixtures.answer("**2 idle.**\n<read_aloud>Both are idle.</read_aloud>"),
      Fixtures.answer("**2 idle.**\n<read_aloud>Both are"),
      Fixtures.answer("ok"),
    ])
    let session = session(gateway)
    for request in ["read me the summary", "again", "thanks"] { _ = try await session.ask(request) }

    let answers = try #require(gateway.requests.last?.messages).filter { $0.role == .assistant }.map(\.content)
    #expect(answers == ["**2 idle.**\n<read_aloud>Both are idle.</read_aloud>", "**2 idle.**"])
  }

  @Test func notesAFailedRequestCarriedReachTheNextOne() async throws {
    let send = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#)
    let gateway = FakeGateway([send, Fixtures.answer("Cancelled.")], failing: [2])
    let session = session(gateway)
    _ = try await session.ask("tell demo to carry on")
    await session.cancel("a1")
    await #expect(throws: FakeGateway.failure) { try await session.ask("did it go?") }
    _ = try await session.ask("did it go?")

    let current = try #require(gateway.requests.last?.messages.last?.content)
    #expect(current.contains("<since_last_reply>\nThe user cancelled a1; nothing was done.\n</since_last_reply>"))
  }

  @Test func anEarlierExchangeNotesTheActionsItQueuedAndWhatHappened() async throws {
    let send = Fixtures.toolCall("c1", "prompt_agent", #"{"pane_id":"w1:p1","message":"carry on"}"#)
    let gateway = FakeGateway([send, Fixtures.answer("Sent."), Fixtures.answer("Yes.")])
    let session = session(gateway)
    _ = try await session.ask("tell demo to carry on")
    try await session.confirm("a1")
    _ = try await session.ask("did it go?")
    _ = try await session.ask("sure?")

    let messages = try #require(gateway.requests.last?.messages)
    #expect(!messages.contains { $0.role == .tool || $0.toolCalls != nil })
    #expect(messages[2].content == "Ready to send to demo / main.")
    #expect(
      messages[1].content == """
        <request>
        tell demo to carry on
        </request>

        <queued>
        - a1: Send to demo / main: carry on
        </queued>
        """)
    #expect(
      messages[3].content == """
        <since_last_reply>
        The user confirmed a1; the message was sent to w1:p1.
        </since_last_reply>

        <request>
        did it go?
        </request>
        """)
  }

  @Test func theConversationSurvivesAcrossRequestsMinutesApart() async throws {
    let clock = TestClock()
    let gateway = FakeGateway([Fixtures.answer("**demo / main**: idle."), Fixtures.answer("Yes, done.")])
    let session = session(gateway, clock: clock)
    _ = try await session.ask("how's the demo agent?")
    clock.advance(by: .seconds(60))
    _ = try await session.ask("is it done yet?")

    #expect(try earlier(gateway) == ["<request>\nhow's the demo agent?\n</request>", "**demo / main**: idle."])
  }

  @Test func aRequestMoreThanTwentyMinutesAfterThePreviousOneStartsFresh() async throws {
    let clock = TestClock()
    let gateway = FakeGateway([Fixtures.answer("first"), Fixtures.answer("second"), Fixtures.answer("third")])
    let session = session(gateway, clock: clock)
    #expect(AssistantSession.Configuration(model: "m").conversationWindow == .seconds(20 * 60))

    _ = try await session.ask("first")
    clock.advance(by: .seconds(20 * 60))
    _ = try await session.ask("second")
    #expect(try earlier(gateway) == ["<request>\nfirst\n</request>", "first"])

    clock.advance(by: .seconds(20 * 60 + 1))
    _ = try await session.ask("third")
    #expect(try earlier(gateway).isEmpty)
  }

  @Test func theSessionSaysWhetherItStillRemembersTheConversation() async throws {
    let clock = TestClock()
    let gateway = FakeGateway([Fixtures.answer("first"), Fixtures.answer("second")])
    let session = session(gateway, clock: clock)
    #expect(await !session.remembers())
    _ = try await session.ask("first")
    clock.advance(by: .seconds(20 * 60))
    #expect(await session.remembers())
    clock.advance(by: .seconds(1))
    #expect(await !session.remembers())

    _ = try await session.ask("second")
    #expect(try earlier(gateway).isEmpty)
    #expect(await session.remembers())
    await session.newConversation()
    #expect(await !session.remembers())
  }

  @Test func aNewConversationForgetsEarlierExchangesAndNotes() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("Which agent?")])
    let session = session(gateway)
    _ = try await session.ask("tell demo to carry on")
    await session.cancel("a1")
    await session.newConversation()
    _ = try await session.ask("is it done yet?")

    let messages = try #require(gateway.requests.last?.messages)
    #expect(messages.map(\.role) == [.system, .user])
    #expect(!(messages[1].content ?? "").contains("since_last_reply"))
  }

  @Test func aRequestStillRunningWhenANewConversationStartsIsNotRemembered() async throws {
    let gateway = SlowScriptedGateway([Fixtures.answer("Late answer."), Fixtures.answer("Which agent?")])
    let session = AssistantSession(
      gateway: gateway, herdr: Fixtures.client(FakeRunner()), configuration: .init(model: "test-model", prefetchLines: 0))
    let late = Task { try await session.ask("how's the demo agent?") }
    try await Task.sleep(for: .milliseconds(10))
    await session.newConversation()
    _ = try await late.value
    _ = try await session.ask("is it done yet?")

    #expect(gateway.script.requests.last?.messages.map(\.role) == [.system, .user])
  }

  @Test func closingTheNoteDropsAWaitingActionUnsentAndNotesIt() async throws {
    let runner = FakeRunner()
    let gateway = FakeGateway([Self.send, Fixtures.answer("No, it wasn't sent.")])
    let session = session(gateway, runner)
    _ = try await session.ask("tell demo to carry on")
    await session.drop(["a1"])
    try await session.confirm("a1")
    _ = try await session.ask("was the message sent?")

    #expect(runner.prompts.isEmpty)
    let current = try #require(gateway.requests.last?.messages.last?.content)
    #expect(
      current.hasPrefix(
        "<since_last_reply>\na1 was dropped because the user closed the note without confirming it; nothing was done.\n"
          + "</since_last_reply>"))
  }

  @Test func onlyAWaitingActionIsDropped() async throws {
    let gateway = FakeGateway([Self.send, Fixtures.answer("Sent.")])
    let session = session(gateway)
    _ = try await session.ask("tell demo to carry on")
    try await session.confirm("a1")
    await session.drop(["a1"])
    _ = try await session.ask("was the message sent?")

    let current = try #require(gateway.requests.last?.messages.last?.content)
    #expect(current.contains("The user confirmed a1"))
    #expect(!current.contains("dropped"))
  }
}
