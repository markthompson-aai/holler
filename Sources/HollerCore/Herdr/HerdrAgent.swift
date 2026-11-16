import Foundation

/// One coding agent running in a Herdr pane, flattened from `herdr api snapshot`
/// so the model and the UI see human labels ("AssemblyAI" / "search") rather
/// than bare ids.
public struct HerdrAgent: Sendable, Equatable, Codable {
  /// Herdr's pane id, e.g. `w6:p3`. The only handle actions are ever sent to.
  public let paneId: String
  /// The agent program, e.g. `claude` or `codex`.
  public let kind: String
  /// Herdr lifecycle state: idle, working, blocked, done or unknown.
  public let status: String
  public let workspace: String
  public let tab: String
  /// Herdr's id for the tab the pane is in, e.g. `w6:t2`. Closing a tab uses it.
  public let tabId: String
  /// Herdr's id for the pane's terminal, when it gave one: the time it opened
  /// in hex microseconds, then a counter. Pane and tab ids start over when
  /// Herdr restarts; this doesn't, so it tells a pane's new agent from its old.
  public let terminalId: String?
  /// The agent's working directory, as an absolute path.
  public let cwd: String
  /// The terminal title the agent set, usually its current task, with
  /// anything that looks like a secret redacted.
  public let title: String
  public let focused: Bool

  public init(
    paneId: String, kind: String, status: String, workspace: String, tab: String, tabId: String = "",
    terminalId: String? = nil, cwd: String, title: String, focused: Bool
  ) {
    self.paneId = paneId
    self.kind = kind
    self.status = status
    self.workspace = workspace
    self.tab = tab
    self.tabId = tabId
    self.terminalId = terminalId
    self.cwd = cwd
    self.title = title
    self.focused = focused
  }
}

extension HerdrAgent {
  /// Whether `now`, the agent found in this one's pane later, is still this
  /// one, for an action whose card names it. Herdr starts its pane and tab
  /// ids over when it restarts, so the same pane id can come to hold someone
  /// else's agent: a different terminal gives that away, where Herdr gave
  /// both, and so does a different tab, or a workspace or tab that's since
  /// been renamed, which the card no longer describes.
  func isStill(_ now: HerdrAgent) -> Bool {
    if let then = terminalId, let current = now.terminalId, then != current { return false }
    return paneId == now.paneId && tabId == now.tabId && workspace == now.workspace && tab == now.tab
  }
}

/// A Herdr workspace a new agent can be started in. Herdr doesn't record a
/// folder per workspace, so `folders` are the ones its panes are open in.
public struct HerdrWorkspace: Sendable, Equatable, Codable {
  public let id: String
  public let label: String
  public let tabs: [String]
  public let folders: [String]

  public init(id: String, label: String, tabs: [String], folders: [String]) {
    self.id = id
    self.label = label
    self.tabs = tabs
    self.folders = folders
  }
}

/// The subset of `herdr api snapshot` we read. Unknown fields are ignored, so
/// newer Herdr versions that add fields keep decoding.
struct HerdrSnapshot: Decodable {
  struct Agent: Decodable {
    /// The agent program's own session, e.g. Claude's session id.
    struct Session: Decodable {
      let value: String?
    }

    let pane_id: String
    let tab_id: String
    let workspace_id: String
    let agent: String?
    let agent_status: String?
    let agent_session: Session?
    let terminal_id: String?
    let cwd: String?
    let terminal_title_stripped: String?
    let focused: Bool?

    /// The agent's session id, which no other agent shares, even after Herdr
    /// restarts and its pane and tab ids start over. Nil until Herdr knows it.
    var sessionId: String? {
      agent_session?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Herdr's id for the pane's terminal: the time it opened, in hex
    /// microseconds, then a counter, so it doesn't repeat after Herdr restarts.
    var terminalId: String? {
      terminal_id.flatMap { $0.isEmpty ? nil : $0 }
    }
  }

  struct Pane: Decodable {
    let pane_id: String?
    let tab_id: String?
    let workspace_id: String
    let cwd: String?
    let terminal_id: String?

    var terminalId: String? {
      terminal_id.flatMap { $0.isEmpty ? nil : $0 }
    }
  }

  struct Tab: Decodable {
    let tab_id: String
    let workspace_id: String?
    let label: String?

    /// The tab's name as Holler uses it everywhere: its label, with anything
    /// that looks like a secret redacted, since it goes to the model with
    /// the agent list; its id when it has no label.
    var name: String { label.map(Redaction.redact) ?? tab_id }
  }

  struct Workspace: Decodable {
    let workspace_id: String
    let label: String?
  }

  let agents: [Agent]
  let panes: [Pane]
  let tabs: [Tab]
  let workspaces: [Workspace]

  private enum CodingKeys: String, CodingKey { case agents, panes, tabs, workspaces }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agents = try container.decode([Agent].self, forKey: .agents)
    panes = try container.decodeIfPresent([Pane].self, forKey: .panes) ?? []
    tabs = try container.decode([Tab].self, forKey: .tabs)
    workspaces = try container.decode([Workspace].self, forKey: .workspaces)
  }

  private struct Envelope: Decodable {
    struct Result: Decodable { let snapshot: HerdrSnapshot }
    let result: Result
  }

  static func decode(_ json: String) throws -> HerdrSnapshot {
    try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).result.snapshot
  }

  var flattened: [HerdrAgent] {
    let tabLabels = Dictionary(tabs.map { ($0.tab_id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let workspaceLabels = Dictionary(
      workspaces.map { ($0.workspace_id, $0.label ?? $0.workspace_id) }, uniquingKeysWith: { a, _ in a })
    return agents.map { raw in
      HerdrAgent(
        paneId: raw.pane_id,
        kind: raw.agent ?? "unknown",
        status: raw.agent_status ?? "unknown",
        workspace: workspaceLabels[raw.workspace_id] ?? raw.workspace_id,
        tab: tabLabels[raw.tab_id] ?? raw.tab_id,
        tabId: raw.tab_id,
        terminalId: raw.terminalId,
        cwd: raw.cwd ?? "",
        // A title is whatever the pane's program set, often the command it's running.
        title: Redaction.redact(raw.terminal_title_stripped ?? ""),
        focused: raw.focused ?? false
      )
    }
  }
}

extension HerdrSnapshot {
  /// The terminal in a pane, from its agent entry or its pane entry: nil
  /// when the pane is gone, `.some(nil)` when Herdr gave the pane no id.
  func terminalId(inPane paneId: String) -> String?? {
    if let agent = agents.first(where: { $0.pane_id == paneId }) { return .some(agent.terminalId) }
    if let pane = panes.first(where: { $0.pane_id == paneId }) { return .some(pane.terminalId) }
    return nil
  }

  /// The workspaces `filter` allows, each with only the folders and tabs it
  /// allows. A tab with a pane or an agent in an excluded folder is left
  /// out, name and all: the name of a hidden agent's tab can say as much as
  /// its screen.
  func workspaceList(allowing filter: AgentFilter) -> [HerdrWorkspace] {
    let hidden = { (folder: String?) in folder.map { !filter.allowsFolder($0) } ?? false }
    let hiddenTabs = Set(
      panes.filter { hidden($0.cwd) }.compactMap(\.tab_id) + agents.filter { hidden($0.cwd) }.map(\.tab_id))
    return workspaces.compactMap { workspace in
      let label = workspace.label ?? workspace.workspace_id
      guard filter.allowsWorkspace(label) else { return nil }
      var folders: [String] = []
      for pane in panes where pane.workspace_id == workspace.workspace_id {
        if let cwd = pane.cwd, !cwd.isEmpty, !hidden(cwd), !folders.contains(cwd) { folders.append(cwd) }
      }
      return HerdrWorkspace(
        id: workspace.workspace_id,
        label: label,
        tabs: tabs.filter { $0.workspace_id == workspace.workspace_id && !hiddenTabs.contains($0.tab_id) }.map(\.name),
        folders: folders)
    }
  }
}
