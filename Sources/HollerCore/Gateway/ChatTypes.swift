import Foundation

/// OpenAI-compatible chat types, as LLM Gateway speaks them.
/// https://www.assemblyai.com/docs/llm-gateway/tool-calling
public struct ChatMessage: Sendable, Equatable, Codable {
  public enum Role: String, Sendable, Codable { case system, user, assistant, tool }

  public var role: Role
  public var content: String?
  public var toolCalls: [ToolCall]?
  public var toolCallId: String?
  /// Claude prompt-caching breakpoint; everything up to this message is cached.
  public var cacheControl: CacheControl?

  public init(
    role: Role, content: String?, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil,
    cacheControl: CacheControl? = nil
  ) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallId = toolCallId
    self.cacheControl = cacheControl
  }

  public static func system(_ text: String, cached: Bool = false) -> ChatMessage {
    ChatMessage(role: .system, content: text, cacheControl: cached ? .ephemeral : nil)
  }

  public static func user(_ text: String) -> ChatMessage {
    ChatMessage(role: .user, content: text)
  }

  public static func tool(callId: String, _ text: String) -> ChatMessage {
    ChatMessage(role: .tool, content: text, toolCallId: callId)
  }

  enum CodingKeys: String, CodingKey {
    case role, content
    case toolCalls = "tool_calls"
    case toolCallId = "tool_call_id"
    case cacheControl = "cache_control"
  }
}

public struct CacheControl: Sendable, Equatable, Codable {
  public var type: String
  public static let ephemeral = CacheControl(type: "ephemeral")
}

public struct ToolCall: Sendable, Equatable, Codable {
  public struct Function: Sendable, Equatable, Codable {
    public var name: String
    /// A JSON object, encoded as a string (and occasionally malformed).
    public var arguments: String
  }

  public var id: String
  public var type: String
  public var function: Function

  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.type = "function"
    self.function = Function(name: name, arguments: arguments)
  }
}

public struct ToolDefinition: Sendable, Equatable, Encodable {
  public struct Function: Sendable, Equatable, Encodable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
  }

  public var type = "function"
  public var function: Function

  public init(name: String, description: String, parameters: JSONValue) {
    function = Function(name: name, description: description, parameters: parameters)
  }
}

public struct ChatRequest: Sendable, Encodable {
  public var model: String
  public var messages: [ChatMessage]
  public var tools: [ToolDefinition]?
  /// `"none"` forbids tool calls (tools must still be sent while the history
  /// holds earlier tool calls); nil leaves the choice to the model.
  public var toolChoice: String?
  public var maxTokens: Int
  /// Omitted when nil: newer Claude models reject the field outright.
  public var temperature: Double?
  /// Claude's effort level (`low`, `medium`, `high`, `xhigh` or `max`), which
  /// the gateway takes as `reasoning_effort`. Omitted when nil: the model's default.
  public var effort: String? = nil
  // No `json-repair` post-processing: the gateway applies it to the reply text
  // too, and it turns a Markdown answer into a broken JSON array. Malformed
  // tool arguments are reported back to the model as a tool error instead.

  enum CodingKeys: String, CodingKey {
    case model, messages, tools, temperature
    case toolChoice = "tool_choice"
    case maxTokens = "max_tokens"
    case effort = "reasoning_effort"
  }
}

public struct ChatUsage: Sendable, Equatable, Decodable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var cachedTokens: Int

  public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedTokens: Int = 0) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedTokens = cachedTokens
  }

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case details = "prompt_tokens_details"
  }

  enum DetailKeys: String, CodingKey {
    case cachedTokens = "cached_tokens"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
    outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    let details = try? container.nestedContainer(keyedBy: DetailKeys.self, forKey: .details)
    cachedTokens = (try? details?.decodeIfPresent(Int.self, forKey: .cachedTokens)) ?? 0
  }

  static func + (lhs: ChatUsage, rhs: ChatUsage) -> ChatUsage {
    ChatUsage(
      inputTokens: lhs.inputTokens + rhs.inputTokens,
      outputTokens: lhs.outputTokens + rhs.outputTokens,
      cachedTokens: lhs.cachedTokens + rhs.cachedTokens
    )
  }
}

/// One completion, with the gateway's choices folded into a single assistant
/// message. LLM Gateway can return a model's text and its tool calls as
/// separate choices, so reading only `choices[0]` would drop tool calls.
public struct ChatCompletion: Sendable, Equatable {
  public var message: ChatMessage
  public var usage: ChatUsage
  public var requestId: String?
}

struct ChatResponse: Decodable {
  struct Choice: Decodable {
    let message: ChatMessage
  }

  let request_id: String?
  let choices: [Choice]
  let usage: ChatUsage?

  var completion: ChatCompletion {
    let text = choices.compactMap(\.message.content)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    let calls = choices.flatMap { $0.message.toolCalls ?? [] }
    let message = ChatMessage(
      role: .assistant,
      content: text.isEmpty ? nil : text,
      toolCalls: calls.isEmpty ? nil : calls
    )
    return ChatCompletion(message: message, usage: usage ?? ChatUsage(), requestId: request_id)
  }
}
