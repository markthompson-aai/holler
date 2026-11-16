import Foundation

/// One tool the model may call. Each owns its schema, how it reads the model's
/// arguments and what it does, and reports exactly one `ToolResult`.
protocol AssistantTool: Sendable {
  var definition: ToolDefinition { get }
  /// Reads only touch Herdr, so a round's reads run concurrently; every other
  /// tool runs on its own, in call order.
  var isRead: Bool { get }
  /// A thrown error goes back to the model as the tool's error result.
  func run(_ arguments: JSONValue, _ context: ToolContext) async throws -> ToolResult
}

extension AssistantTool {
  var name: String { definition.function.name }
  var isRead: Bool { false }
}

/// What a tool call reports to the turn.
enum ToolResult: Sendable {
  /// Text for the model, which carries on. `about` holds the pane ids of any
  /// agents it read, which join the conversation's focus.
  case text(String, about: [String] = [])
  /// An action for the user to confirm, or to run after a countdown when it
  /// is simple and the user has allowed that. The model is told which; a
  /// round that only queues actions ends the turn, since their cards are the
  /// answer. `replacing` names an earlier waiting card it corrects, which is
  /// dropped once the turn succeeds. `showFirst` keeps its card waiting
  /// whatever the setting, because the user asked to see it first.
  case queued(any ActionDefinition, replacing: String? = nil, showFirst: Bool = false)
  /// An alert for this agent stopping work, for the session to keep until
  /// then. The model is told the agent's status now, and carries on.
  case alert(HerdrAgent)
  /// The turn ends here with `answer`, without another model call. `result`
  /// is still recorded as the tool's result, so a follow-up sees it.
  case endTurn(answer: String, result: String, focused: HerdrAgent?)

  static func error(_ message: String) -> ToolResult {
    let encoded = (try? String(decoding: JSONEncoder().encode(["error": message]), as: UTF8.self)) ?? ""
    return .text(encoded.isEmpty ? #"{"error":"tool failed"}"# : encoded)
  }
}

struct ToolContext: Sendable {
  let herdr: HerdrClient
  let onEvent: @Sendable (AssistantEvent) -> Void
}

/// A tool call the model got wrong, worded for the model.
struct ToolError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

enum AssistantTools {
  /// Every tool offered to the model, in the order it sees them.
  static let all: [any AssistantTool] = [
    ListAgentsTool(), ReadAgentsTool(), FocusAgentTool(), SendAction.Tool(), StartAction.Tool(), CloseAction.Tool(),
    InterruptAction.Tool(), TellMeWhenTool(),
  ]

  /// Herdr's pane ids, e.g. `w6:p3`, `w6:p1G` or `wH:pA`.
  static let paneIdPattern = "w[0-9A-Za-z]+:p[0-9A-Za-z]+"

  /// The argument every action tool takes so a correction replaces the card
  /// it corrects, rather than leaving both waiting.
  static let replaces: JSONValue = [
    "type": "string",
    "pattern": "a[0-9]+",
    "description": """
      Only for a correction: the action id of an earlier card still waiting that this one \
      replaces, e.g. "a1" when the user says "actually, say this instead". That card is dropped \
      unsent. Leave it out for an action in addition to earlier ones, e.g. "and also tell it…".
      """,
  ]

  /// The argument an action tool takes so that a request to see the action
  /// first keeps its card, even once simple actions run after a countdown.
  static let confirm: JSONValue = [
    "type": "boolean",
    "description": """
      Only when the user asks to see, check or draft the action before it goes, or not to run \
      it yet, for example "show me first", "draft a message to the api agent" or "don't send it \
      yet": true keeps its card waiting for them, even when Holler would otherwise run it after \
      a countdown. Leave it out otherwise.
      """,
  ]

  static func named(_ name: String) -> (any AssistantTool)? {
    all.first { $0.name == name }
  }
}
