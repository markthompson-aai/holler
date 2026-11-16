import Foundation

/// A fresh agent list, as in the user's message.
struct ListAgentsTool: AssistantTool {
  var isRead: Bool { true }

  var definition: ToolDefinition {
    ToolDefinition(
      name: "list_agents",
      description: """
        Refresh the list of agents and their statuses. The list in the user's message is \
        already current, so only call this if the user asks you to check again.
        """,
      parameters: ["type": "object", "properties": [:]]
    )
  }

  func run(_ arguments: JSONValue, _ context: ToolContext) async throws -> ToolResult {
    let state = try await context.herdr.state()
    return .text(AssistantPrompt.agentList(state.agents, startedTabs: state.startedTabs, now: Date()))
  }
}
