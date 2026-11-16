import Foundation

/// Something the user asked to be told about later, so they needn't ask
/// again: an agent stopping work. Holler keeps it until the agent finishes,
/// ends by needing them, or closes, then shows a quiet note. It outlives the
/// note and the conversation; only firing, or quitting Holler, ends it.
public struct Alert: Sendable, Equatable, Identifiable {
  /// "t1", "t2": t for "tell me when", counted up through the session, so
  /// the model can name one and an action's "a1" is never mistaken for it.
  public let id: String
  /// The agent whose stopping fires it.
  public let paneId: String
  /// "demo / api", as the note names agents.
  public let name: String
  /// The user's words, shown over the note when it fires.
  public let request: String

  public init(id: String, paneId: String, name: String, request: String) {
    self.id = id
    self.paneId = paneId
    self.name = name
    self.request = request
  }

  /// An alert that has happened, as the note shows it.
  public struct Fired: Sendable, Equatable {
    public let alert: Alert
    /// What the note says, in Markdown: "**demo / api** has finished."
    public let answer: String

    public init(alert: Alert, answer: String) {
      self.alert = alert
      self.answer = answer
    }
  }
}

/// Sets an alert for an agent stopping work. Nothing happens in Herdr, and
/// nothing shows until it does.
struct TellMeWhenTool: AssistantTool {
  var definition: ToolDefinition {
    ToolDefinition(
      name: "tell_me_when",
      description: """
        Set a quiet note to tell the user when an agent stops working: it finishes, ends by \
        needing them, or closes. Only call this when the user asks to be told, alerted, notified \
        or reminded when an agent finishes, is done or needs them, for example "tell me when the \
        api agent finishes" or "let me know when search is done". Nothing is sent to the agent, \
        and the note shows on its own when it happens. The result says the agent's status now: \
        one that isn't working will be reported the next time it stops.
        """,
      parameters: [
        "type": "object",
        "properties": [
          "pane_id": [
            "type": "string",
            "pattern": .string(AssistantTools.paneIdPattern),
            "description": "The agent's pane id from the agent list.",
          ]
        ],
        "required": ["pane_id"],
      ]
    )
  }

  func run(_ arguments: JSONValue, _ context: ToolContext) async throws -> ToolResult {
    guard let paneId = arguments["pane_id"]?.stringValue else { throw ToolError("pane_id is required") }
    return .alert(try await context.herdr.resolve(paneId))
  }
}
