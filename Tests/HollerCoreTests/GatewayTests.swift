import Foundation
import Testing

@testable import HollerCore

@Suite struct GatewayTests {
  @Test func toolCallsSplitAcrossChoicesAreMerged() throws {
    // The shape from the LLM Gateway tool-calling docs: text and tool call
    // arrive as separate choices.
    let json = """
      {"request_id":"abc123","choices":[
        {"index":0,"finish_reason":"tool_use","message":{"role":"assistant","content":"I'll check."}},
        {"index":1,"finish_reason":"tool_use","message":{"role":"assistant","content":"","tool_calls":[
          {"id":"call_123","type":"function","function":{"name":"read_agents","arguments":"{\\"pane_ids\\":[\\"w1:p1\\"]}"}}
        ]}}
      ],"usage":{"input_tokens":120,"output_tokens":25,"total_tokens":145,
        "prompt_tokens_details":{"cached_tokens":100}}}
      """
    let completion = try JSONDecoder().decode(ChatResponse.self, from: Data(json.utf8)).completion
    #expect(completion.message.content == "I'll check.")
    #expect(completion.message.toolCalls?.map(\.id) == ["call_123"])
    #expect(completion.usage == ChatUsage(inputTokens: 120, outputTokens: 25, cachedTokens: 100))
    #expect(completion.requestId == "abc123")
  }

  @Test func requestEncodesGatewayFieldNames() throws {
    let request = ChatRequest(
      model: "claude-haiku-5-5",
      messages: [.system("sys", cached: true), .tool(callId: "c1", "result")],
      tools: [ReadAgentsTool().definition],
      toolChoice: "none",
      maxTokens: 100,
      temperature: 0.2
    )
    let json = String(decoding: try LLMGateway.encoder.encode(request), as: UTF8.self)
    #expect(json.contains(#""cache_control":{"type":"ephemeral"}"#))
    #expect(json.contains(#""tool_call_id":"c1""#))
    #expect(json.contains(#""tool_choice":"none""#))
    #expect(json.contains(#""max_tokens":100"#))
    #expect(!json.contains("post_processing_steps"))
    #expect(json.contains(#""name":"read_agents""#))
    #expect(!json.contains("toolCalls"))
    #expect(!json.contains("reasoning_effort"))
  }

  @Test func effortEncodesAsReasoningEffort() throws {
    let request = ChatRequest(
      model: "claude-sonnet-5-5", messages: [.system("sys", cached: true)], maxTokens: 100, effort: "low")
    let json = String(decoding: try LLMGateway.encoder.encode(request), as: UTF8.self)
    #expect(json.contains(#""reasoning_effort":"low""#))
  }

  @Test func dotEnvParsing() {
    let parsed = DotEnv.parse(
      """
      # comment
      ASSEMBLYAI_API_KEY=abc123
      export HOLLER_MODEL="claude-sonnet-5-5"
      EMPTY=
      QUOTED='a=b'
      not a pair
      """)
    #expect(
      parsed == [
        "ASSEMBLYAI_API_KEY": "abc123", "HOLLER_MODEL": "claude-sonnet-5-5", "EMPTY": "", "QUOTED": "a=b",
      ])
  }

  @Test func aCommentAfterAValueIsNotPartOfIt() {
    let parsed = DotEnv.parse(
      """
      HOLLER_WORKSPACES=demo # only the demo
      HOLLER_MODEL = claude-sonnet-5-5\t# the default
      HOLLER_VOICE="Zoe (Premium)"  # by name
      HOLLER_HOTKEY='fn' # the globe key
      EMPTY= # nothing yet
      COLOUR=#fff
      ISSUE=fix#12
      QUOTED="a # b"
      APOSTROPHE='it's fine'
      OPEN="unclosed # kept
      """)
    #expect(
      parsed == [
        "HOLLER_WORKSPACES": "demo", "HOLLER_MODEL": "claude-sonnet-5-5", "HOLLER_VOICE": "Zoe (Premium)",
        "HOLLER_HOTKEY": "fn", "EMPTY": "", "COLOUR": "#fff", "ISSUE": "fix#12", "QUOTED": "a # b",
        "APOSTROPHE": "it's fine", "OPEN": "\"unclosed",
      ])
    #expect(Settings(environment: parsed).filter.workspaces == ["demo"])
  }

  @Test func settingsTreatEmptyValuesAsUnset() {
    let settings = Settings(environment: [
      "ASSEMBLYAI_API_KEY": "  ", "HOLLER_EXCLUDE_PATHS": "/a:/b", "HOLLER_WORKSPACES": "demo, staging",
    ])
    #expect(settings.apiKey == nil)
    #expect(settings.model == Settings.defaultModel)
    #expect(settings.effort == "medium")
    #expect(Settings(environment: ["HOLLER_EFFORT": "default"]).effort == nil)
    #expect(Settings(environment: ["HOLLER_EFFORT": "low"]).effort == "low")
    #expect(settings.filter == AgentFilter(excludedPathPrefixes: ["/a", "/b"], workspaces: ["demo", "staging"]))
  }
}
