import Foundation

/// Interrupting a working agent by sending it Esc, which stops what it is
/// doing and leaves it at its prompt with its tab open. Any agent Holler can
/// see can be interrupted, but only while it is working: an idle one has
/// nothing to stop, and Esc would dismiss a blocked one's prompt.
public struct InterruptAction: ActionDefinition, Equatable {
  let target: AgentToInterrupt

  public init(_ target: AgentToInterrupt) {
    self.target = target
  }

  /// Queues an interrupt for the user to confirm.
  struct Tool: AssistantTool {
    var definition: ToolDefinition {
      ToolDefinition(
        name: "interrupt_agent",
        description: """
          Queue interrupting a working agent: it gets Esc, stops what it is doing and waits at \
          its prompt, with its tab left open. Nothing happens until the user confirms on screen. \
          Works on any agent in the list, but only one whose status is "working". Only call this \
          when the user explicitly asks to stop, interrupt or cancel what an agent is doing.
          """,
        parameters: [
          "type": "object",
          "properties": [
            "pane_id": [
              "type": "string",
              "pattern": .string(AssistantTools.paneIdPattern),
              "description": "The pane id of the working agent to interrupt, from the agent list.",
            ],
            "replaces": AssistantTools.replaces,
          ],
          "required": ["pane_id"],
        ]
      )
    }

    func run(_ arguments: JSONValue, _ context: ToolContext) async throws -> ToolResult {
      guard let paneId = arguments["pane_id"]?.stringValue else { throw ToolError("pane_id is required") }
      return .queued(
        InterruptAction(try await context.herdr.checkInterrupt(paneId: paneId)), replacing: arguments["replaces"]?.stringValue)
    }
  }

  public var card: ConfirmCard {
    ConfirmCard(
      kind: .interrupt, verb: "Interrupt", target: "\(target.agent.workspace) / \(target.agent.tab)",
      placeholder: "It stops what it's doing and waits at its prompt. The tab stays open.",
      details: [
        .init(label: "\(target.agent.kind.capitalized) · working", text: target.lastLine, placeholder: "No output yet.")
      ],
      words: .init(
        button: "Interrupt", busy: "Interrupting…", done: "Interrupted", cancelled: "Cancelled. Nothing was interrupted.",
        failed: "Not interrupted"))
  }

  var ready: String { "Ready to interrupt \(target.agent.workspace) / \(target.agent.tab)." }

  var about: [String] { [target.agent.paneId] }

  func run(_ id: String, herdr: HerdrClient, by trigger: ActionTrigger) async throws -> (agent: HerdrAgent?, note: String) {
    let agent = try await herdr.interrupt(target)
    return (
      agent, "\(trigger.opening(id)); \(agent.paneId) was sent Esc to interrupt it, and should now be waiting at its prompt."
    )
  }

  func failedNote(_ id: String, _ error: any Error, by trigger: ActionTrigger) -> String {
    "\(trigger.opening(id)) but the agent was not interrupted: \(error)"
  }
}
