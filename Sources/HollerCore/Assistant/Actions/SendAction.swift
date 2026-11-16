import Foundation

/// Sending a message to an agent that is already running, as if the user
/// typed it at the agent's prompt. A blocked agent is refused, and so is a
/// pane that no longer holds the agent the card names. Simple enough
/// for a countdown when the agent is idle or done (ADR 0001).
public struct SendAction: ActionDefinition, Equatable {
  let agent: HerdrAgent
  let text: String

  public init(agent: HerdrAgent, text: String) {
    self.agent = agent
    self.text = text
  }

  /// Queues a send for the user to confirm, or to count down.
  struct Tool: AssistantTool {
    var definition: ToolDefinition {
      ToolDefinition(
        name: "prompt_agent",
        description: """
          Queue a message to send to an agent, as if the user typed it at that agent's prompt. \
          Nothing is sent until the user confirms on screen, or, when they have allowed simple \
          actions to run without a card, until a short countdown they can cancel has ended; the \
          result says which. Only call this when the user explicitly asks you to tell, ask or \
          instruct an agent to do something. Do not call it for summaries or questions about agents.
          """,
        parameters: [
          "type": "object",
          "properties": [
            "pane_id": [
              "type": "string",
              "pattern": .string(AssistantTools.paneIdPattern),
              "description": "The target agent's pane id from the agent list.",
            ],
            "message": [
              "type": "string",
              "description": """
                The message for the agent, written as the user would type it: direct, specific \
                and faithful to what they asked. Don't add tasks they didn't ask for. Never start \
                it with ! or / unless the user asked for exactly that shell command or slash \
                command: the agent runs such a message instead of reading it, so it always waits \
                for the user to confirm, with a warning on its card.
                """,
            ],
            "confirm": AssistantTools.confirm,
            "replaces": AssistantTools.replaces,
          ],
          "required": ["pane_id", "message"],
        ]
      )
    }

    func run(_ arguments: JSONValue, _ context: ToolContext) async throws -> ToolResult {
      guard let paneId = arguments["pane_id"]?.stringValue, let rawMessage = arguments["message"]?.stringValue else {
        throw ToolError("pane_id and message are required")
      }
      let message = try HerdrClient.sanitize(rawMessage)
      let agent = try await context.herdr.resolve(paneId)
      if agent.status == "blocked" {
        throw ToolError("\(paneId) is blocked waiting for approval in its terminal; it can't take a message")
      }
      return .queued(
        SendAction(agent: agent, text: message), replacing: arguments["replaces"]?.stringValue,
        showFirst: arguments["confirm"]?.boolValue ?? false)
    }
  }

  public var card: ConfirmCard {
    ConfirmCard(
      kind: .send, verb: "Send to", target: "\(agent.workspace) / \(agent.tab)", body: text,
      warnings: [DirectInput(text)?.warning].compactMap { $0 },
      words: .init(
        button: "Send", busy: "Sending…", done: "Sent", cancelled: "Cancelled. Nothing was sent.", failed: "Not sent",
        countdown: "Sending in", runNow: "Send now"))
  }

  var ready: String { "Ready to send to \(agent.workspace) / \(agent.tab)." }

  var underway: String { "Sending to \(agent.workspace) / \(agent.tab)." }

  var about: [String] { [agent.paneId] }

  /// An idle or done agent takes a message cleanly. One that is working would
  /// get it mid-task, so that waits on a card, as does one that has gone. So
  /// does a message the agent would run rather than read, whoever it's for.
  var simplicity: Simplicity {
    DirectInput(text).map { .waits(because: $0.waitReason) } ?? simplicity(agent.status, since: false)
  }

  func simplicity(in state: HerdrState) -> Simplicity {
    if let direct = DirectInput(text) { return .waits(because: direct.waitReason) }
    guard let now = state.agents.first(where: { $0.paneId == agent.paneId }) else {
      return .waits(because: "\(agent.tab) is no longer open, so this waits for you.")
    }
    guard agent.isStill(now) else {
      return .waits(because: "\(agent.tab) is no longer in that pane, so this waits for you.")
    }
    return simplicity(now.status, since: true)
  }

  /// Named by its tab, as the user calls an agent: "api is working", or at
  /// the end of a countdown, `since` it began, "api started working".
  private func simplicity(_ status: String, since: Bool) -> Simplicity {
    let why: String
    switch status {
    case "idle", "done": return .simple
    case "working": why = since ? "started working" : "is working"
    case "blocked": why = "needs you"
    default: why = "is \(status)"
    }
    return .waits(because: "\(agent.tab) \(why), so this waits for you.")
  }

  func run(_ id: String, herdr: HerdrClient, by trigger: ActionTrigger) async throws -> (agent: HerdrAgent?, note: String) {
    let agent = try await herdr.prompt(agent, message: text)
    return (agent, "\(trigger.opening(id)); the message was sent to \(agent.paneId).")
  }

  func failedNote(_ id: String, _ error: any Error, by trigger: ActionTrigger) -> String {
    "\(trigger.opening(id)) but sending failed: \(error)"
  }
}
