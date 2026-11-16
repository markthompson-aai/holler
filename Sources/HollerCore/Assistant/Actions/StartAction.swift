import Foundation

/// Starting a new agent in a new tab, or in a fresh git worktree in its own
/// workspace, optionally with a first task. An agent that stops at a question
/// while starting, usually whether to trust the folder, is left open for the
/// user to answer, and its task isn't sent. A new tab is simple enough for a
/// countdown; a worktree is not (ADR 0001).
public struct StartAction: ActionDefinition, Equatable {
  let new: NewAgent

  public init(_ new: NewAgent) {
    self.new = new
  }

  /// Queues a start for the user to confirm, or to count down.
  struct Tool: AssistantTool {
    var definition: ToolDefinition {
      ToolDefinition(
        name: "start_agent",
        description: """
          Queue starting a new coding agent in a new tab, optionally with a first task. Nothing \
          happens until the user confirms on screen, or, when they have allowed simple actions to run \
          without a card, until a short countdown they can cancel has ended; the result says which. \
          A start in a worktree always waits for them to confirm. Only call this when the user \
          explicitly asks to start, create, open or spin up a new agent.
          """,
        parameters: [
          "type": "object",
          "properties": [
            "agent": [
              "type": "string",
              "enum": .array(AgentKind.allCases.map { .string($0.rawValue) }),
              "description": """
                Which agent to start: "codex" only if the user asked for Codex (it can be misheard, \
                e.g. as "codecs"), otherwise "claude".
                """,
            ],
            "workspace": [
              "type": "string",
              "description": "Label of the workspace for the new tab, from the workspace list.",
            ],
            "folder": [
              "type": "string",
              "description": """
                The folder the agent works in, as an absolute or ~ path. Use a folder from the \
                workspace list or one the user named.
                """,
            ],
            "tab_name": [
              "type": "string",
              "description": "A short name for the new tab, e.g. \"tests\" or \"api-docs\".",
            ],
            "worktree": [
              "type": "boolean",
              "description": """
                Start the agent in a fresh git worktree of the folder's repository instead, on a new \
                branch named after tab_name, so it can't collide with other agents in the same \
                repository. It opens as its own workspace, named tab_name. Only when the user asks for \
                a worktree, a separate checkout or a new branch.
                """,
            ],
            "task": [
              "type": "string",
              "description": """
                The agent's first message, written as the user would type it: direct, specific and \
                faithful to what they asked. Leave it out if they didn't give the agent anything to do. \
                Never start it with ! or / unless the user asked for exactly that shell command or \
                slash command: the agent runs such a task instead of reading it, so the start always \
                waits for the user to confirm, with a warning on its card.
                """,
            ],
            "confirm": AssistantTools.confirm,
            "replaces": AssistantTools.replaces,
          ],
          "required": ["workspace", "folder", "tab_name"],
        ]
      )
    }

    func run(_ arguments: JSONValue, _ context: ToolContext) async throws -> ToolResult {
      guard let workspace = arguments["workspace"]?.stringValue, let folder = arguments["folder"]?.stringValue,
        let tab = arguments["tab_name"]?.stringValue
      else {
        throw ToolError("workspace, folder and tab_name are required")
      }
      let new = try await context.herdr.checkNewAgent(
        kind: arguments["agent"]?.stringValue, workspace: workspace, folder: folder, tab: tab, task: arguments["task"]?.stringValue,
        worktree: arguments["worktree"]?.boolValue ?? false)
      return .queued(
        StartAction(new), replacing: arguments["replaces"]?.stringValue, showFirst: arguments["confirm"]?.boolValue ?? false)
    }
  }

  public var card: ConfirmCard {
    let words = ConfirmCard.Words(
      button: "Start", busy: "Starting…", done: "Started", cancelled: "Cancelled. Nothing was started.", failed: "Didn't finish",
      countdown: "Starting in", runNow: "Start now")
    let warnings = [DirectInput(new.task)?.warning].compactMap { $0 }
    guard let worktree = new.worktree else {
      return ConfirmCard(
        kind: .start, verb: "Start \(new.kind.displayName) in", target: "\(new.workspace.label) / \(new.tab)",
        subtitle: Self.tilde(new.folder), body: new.task, placeholder: "No task; it will wait for you.", warnings: warnings,
        words: words)
    }
    return ConfirmCard(
      kind: .start, verb: "Start \(new.kind.displayName) in a worktree,", target: new.tab, subtitle: Self.tilde(worktree.path),
      body: new.task, placeholder: "No task; it will wait for you.",
      details: [
        .init(label: "Branch", text: "\(worktree.branch), new, from \(Self.tilde(new.folder))"),
        .init(label: "Workspace", text: "Its own, \"\(new.tab)\", not a tab in \(new.workspace.label)"),
      ],
      warnings: warnings, words: words)
  }

  var ready: String {
    guard new.worktree != nil else { return "Ready to start \(new.kind.displayName) in \(new.workspace.label) / \(new.tab)." }
    return "Ready to start \(new.kind.displayName) in a new worktree, \(new.tab)."
  }

  var underway: String { "Starting \(new.kind.displayName) in \(new.workspace.label) / \(new.tab)." }

  /// A new tab in a workspace that's already open is simple. A worktree
  /// leaves a checkout and a branch behind, so it waits on its card, and so
  /// does a first task the agent would run rather than read.
  var simplicity: Simplicity {
    guard new.worktree == nil else { return .waits(because: "Worktree starts wait for you.") }
    return DirectInput(new.task).map { .waits(because: $0.waitReason) } ?? .simple
  }

  /// At the end of the countdown the workspace must still be open, and one
  /// the workspace filter allows; the folder is checked again as it starts.
  func simplicity(in state: HerdrState) -> Simplicity {
    guard case .simple = simplicity else { return simplicity }
    guard state.workspaces.contains(where: { $0.id == new.workspace.id }) else {
      return .waits(because: "Holler can no longer see the \(new.workspace.label) workspace, so this waits for you.")
    }
    return .simple
  }

  /// Where the new agent lands, for the model: "demo / tests", or the
  /// worktree's own workspace, its branch and checkout.
  private var place: String {
    guard let worktree = new.worktree else { return "\(new.workspace.label) / \(new.tab)" }
    return "a new git worktree at \(worktree.path) on branch \(worktree.branch), in its own workspace \"\(new.tab)\""
  }

  private static func tilde(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~", options: .anchored)
  }

  /// None yet: once started, the new agent is read on the next request
  /// because it's new.
  var about: [String] { [] }

  func run(_ id: String, herdr: HerdrClient, by trigger: ActionTrigger) async throws -> (agent: HerdrAgent?, note: String) {
    let agent = try await herdr.start(new)
    let task = new.task == nil ? "with no task yet" : "and was given its task"
    return (
      agent,
      "\(trigger.opening(id)); a new \(new.kind.displayName) agent started in \(agent.paneId) "
        + "(\(agent.workspace) / \(agent.tab)\(new.worktree.map { ", a new git worktree on branch \($0.branch)" } ?? "")) \(task)."
    )
  }

  func failedReason(_ error: any Error) -> String {
    guard case HerdrError.startupBlocked(let paneId) = error else { return AssistantSession.describe(error) }
    return "The agent opened in \(paneId) but is waiting for you there, usually to ask whether to trust the folder. "
      + "Answer it in that tab; nothing else was sent"
  }

  func failedNote(_ id: String, _ error: any Error, by trigger: ActionTrigger) -> String {
    guard case HerdrError.startupBlocked(let paneId) = error else {
      return "\(trigger.opening(id)) but starting the agent failed: \(error)"
    }
    return "\(trigger.opening(id)); \(new.kind.displayName) opened in \(paneId) (\(place)) but "
      + "stopped at a question in its terminal, usually whether to trust the folder. Its task was not sent. "
      + "Once the user has answered it there, the task can be sent with prompt_agent."
  }
}
