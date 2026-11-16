import Foundation
import Testing

@testable import HollerCore

/// Read Answers Aloud: every answer is spoken while the setting is on, which
/// the model is told with each request (ADR 0002).
@Suite struct ReadAloudSettingTests {
  @Test func theModelIsToldTheSettingWithEachRequest() async throws {
    let gateway = FakeGateway([Fixtures.answer("ok"), Fixtures.answer("ok")])
    let session = AssistantSession(
      gateway: gateway, herdr: Fixtures.client(FakeRunner()), configuration: .init(model: "test", prefetchLines: 0))

    _ = try await session.ask("summarise", readAloud: true)
    #expect(gateway.lastUserRequest.contains("<settings>\nread answers aloud: on\n</settings>"))
    _ = try await session.ask("summarise")
    #expect(gateway.lastUserRequest.contains("<settings>\nread answers aloud: off\n</settings>"))
  }

  @Test func aReplyThatOnlyQueuesACardIsNeverSpoken() async throws {
    let gateway = FakeGateway([
      ChatMessage(
        role: .assistant, content: "Sending it on.\n<read_aloud>Sending it on.</read_aloud>",
        toolCalls: [ToolCall(id: "c1", name: "prompt_agent", arguments: #"{"pane_id":"w1:p1","message":"go"}"#)])
    ])
    let session = AssistantSession(
      gateway: gateway, herdr: Fixtures.client(FakeRunner()), configuration: .init(model: "test", prefetchLines: 0))
    let turn = try await session.ask("tell main to go", readAloud: true)
    #expect(turn.actions.count == 1 && turn.answer == "Sending it on." && turn.spoken == nil)
  }

  @Test func thePromptSaysWhatTheSettingMeans() {
    #expect(AssistantPrompt.system.contains("<settings>"))
    #expect(AssistantPrompt.system.contains("just show me"))
  }

  @MainActor @Test func theControllerPassesItsSettingOnEachRequest() async {
    let gateway = FakeGateway([
      Fixtures.answer("**1 idle.**\n<read_aloud>One idle.</read_aloud>"), Fixtures.answer("**1 idle.**"),
    ])
    let (herdr, speaker) = (Fixtures.client(FakeRunner()), FakeSpeaker())
    let controller = AssistantController(voice: FakeVoice(), speaker: speaker, herdr: herdr) {
      AssistantSession(gateway: gateway, herdr: herdr, configuration: .init(model: "test", prefetchLines: 0))
    }
    #expect(controller.readsAnswersAloud)
    controller.ask("summarise")
    await controller.settle()
    #expect(gateway.lastUserRequest.contains("read answers aloud: on"))
    #expect(speaker.events == ["speak: One idle."])

    controller.readsAnswersAloud = false
    controller.ask("summarise")
    await controller.settle()
    #expect(gateway.lastUserRequest.contains("read answers aloud: off"))
    #expect(speaker.events == ["speak: One idle."])
  }
}
