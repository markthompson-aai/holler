import Foundation

/// A jump: happens straight away, with no card, since it only moves the
/// user's view. The note closes, so the turn ends with no further model call.
struct FocusAgentTool: AssistantTool {
  var definition: ToolDefinition {
    ToolDefinition(
      name: "focus_agent",
      description: """
        Show the user an agent: switch Herdr to its tab and pane and bring the terminal to the \
        front. It happens straight away and closes the note; nothing is sent to the agent. Only \
        call this when the user asks to see, show, go to, jump to or switch to an agent.
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
    let shown = try await context.herdr.focus(paneId: paneId)
    return .endTurn(answer: "Showing \(shown.workspace) / \(shown.tab).", result: #"{"status":"shown"}"#, focused: shown)
  }
}
