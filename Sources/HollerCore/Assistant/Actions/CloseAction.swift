import Foundation

/// Closing a tab Holler started, which stops every agent in it, whatever it
/// is doing. The card lists each agent and warns about any that are busy.
public struct CloseAction: ActionDefinition, Equatable {
  let tab: TabToClose

  public init(_ tab: TabToClose) {
    self.tab = tab
  }

  /// Queues a close for the user to confirm.
  struct Tool: AssistantTool {
    var definition: ToolDefinition {
      ToolDefinition(
        name: "close_tab",
        description: """
          Queue closing a tab, which stops every agent in it. Nothing happens until the user \
          confirms on screen. Only tabs marked "started by Holler" in the agent list can be closed. \
          Only call this when the user explicitly asks to close a tab or agent.
          """,
        parameters: [
          "type": "object",
          "properties": [
            "pane_id": [
              "type": "string",
              "pattern": .string(AssistantTools.paneIdPattern),
              "description": "The pane id of an agent in the tab to close, from the agent list.",
            ],
            "replaces": AssistantTools.replaces,
          ],
          "required": ["pane_id"],
        ]
      )
    }

    func run(_ arguments: JSONValue, _ context: ToolContext) async throws -> ToolResult {
      guard let paneId = arguments["pane_id"]?.stringValue else { throw ToolError("pane_id is required") }
      return .queued(CloseAction(try await context.herdr.checkClose(paneId: paneId)), replacing: arguments["replaces"]?.stringValue)
    }
  }

  public var card: ConfirmCard {
    ConfirmCard(
      kind: .close, verb: "Close", target: "\(tab.workspace) / \(tab.tab)",
      details: tab.agents.map { closing in
        .init(
          label: "\(closing.agent.kind.capitalized) · \(Self.state(closing.agent.status))", text: closing.lastLine,
          placeholder: "No output yet.")
      },
      warnings: warnings,
      words: .init(
        button: "Close", busy: "Closing…", done: "Closed", cancelled: "Cancelled. Nothing was closed.", failed: "Not closed"))
  }

  /// What closing would interrupt: Herdr closes a tab whatever its agents are
  /// doing, so the card says so rather than refusing.
  private var warnings: [String] {
    tab.agents.compactMap { closing in
      let name = tab.agents.count == 1 ? tab.tab : closing.agent.kind.capitalized + " (\(closing.agent.paneId))"
      switch closing.agent.status {
      case "working": return "\(name) is working; closing stops it."
      case "blocked": return "\(name) is waiting on you; closing ends it unanswered."
      default: return nil
      }
    }
  }

  /// The agent's Herdr state in the summary's words.
  private static func state(_ status: String) -> String {
    switch status {
    case "blocked": "needs you"
    case "done": "idle"
    default: status
    }
  }

  var ready: String { "Ready to close \(tab.workspace) / \(tab.tab)." }

  var about: [String] { tab.agents.map(\.agent.paneId) }

  func run(_ id: String, herdr: HerdrClient, by trigger: ActionTrigger) async throws -> (agent: HerdrAgent?, note: String) {
    let closed = try await herdr.close(tab)
    let stopped = closed.agents.map { "\($0.agent.paneId) (\($0.agent.kind))" }
    return (
      nil,
      "\(trigger.opening(id)); the tab \(closed.workspace) / \(closed.tab) was closed"
        + (stopped.isEmpty ? "." : ", ending " + stopped.joined(separator: " and ") + ".")
    )
  }

  func failedNote(_ id: String, _ error: any Error, by trigger: ActionTrigger) -> String {
    "\(trigger.opening(id)) but the tab was not closed: \(error)"
  }
}
