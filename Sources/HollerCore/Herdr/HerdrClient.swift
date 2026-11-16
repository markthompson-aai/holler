import Foundation
import Synchronization

public enum HerdrError: Error, Equatable, CustomStringConvertible {
  case notInstalled
  case commandFailed(command: String, detail: String)
  case unparseable(String)
  case unknownPane(String)
  case invalidMessage(String)
  case unknownWorkspace(String)
  case invalidFolder(String, reason: String)
  case unknownAgentKind(String)
  /// The agent launched but stopped at a question in its terminal before it
  /// was ready, usually asking whether to trust the folder.
  case startupBlocked(paneId: String)
  case taskNotSent(paneId: String, detail: String)
  case unknownTab(String)
  /// Holler only closes tabs it started itself.
  case notStartedByHoller(tab: String)
  /// The tab has a pane the filter hides, so closing it would end something
  /// Holler isn't allowed to touch.
  case tabHasHiddenPanes(tab: String)
  /// No agent Holler can see has this name, "workspace / tab".
  case noAgentNamed(String)
  /// More than one agent Holler can see has this name, so it won't guess.
  case severalAgentsNamed(String)
  /// Only a working agent can be interrupted; `status` is what it is instead.
  case notWorking(paneId: String, status: String)
  /// The pane now holds a different agent from the one on the card, or the
  /// agent has moved or been renamed since the card was made.
  case agentChanged(String)
  /// The agent is waiting on the user in its terminal, where a message
  /// would answer its approval or question for them.
  case agentBlocked(paneId: String)
  /// Holler won't start an agent in a new worktree, or Herdr wouldn't make
  /// one, e.g. for a repository it doesn't trust.
  case worktreeRefused(String)

  public var description: String {
    switch self {
    case .notInstalled: "herdr was not found (set HERDR_PATH)"
    case .commandFailed(let command, let detail): "herdr \(command) failed: \(detail)"
    case .unparseable(let detail): "could not parse herdr output: \(detail)"
    case .unknownPane(let pane): "no readable agent in pane \(pane)"
    case .invalidMessage(let reason): "message rejected: \(reason)"
    case .unknownWorkspace(let name): "no workspace called \"\(name)\""
    case .invalidFolder(let path, let reason): "can't start an agent in \(path): \(reason)"
    case .unknownAgentKind(let kind):
      "can't start \"\(kind)\"; Holler can start " + AgentKind.allCases.map(\.rawValue).joined(separator: " or ")
    case .startupBlocked(let pane): "the agent in \(pane) stopped at a question while starting"
    case .taskNotSent(let pane, let detail): "the agent started in \(pane) but its task wasn't sent: \(detail)"
    case .unknownTab(let tab): "tab \(tab) is no longer open"
    case .notStartedByHoller(let tab): "Holler can only close tabs it started, and \"\(tab)\" isn't one of them"
    case .tabHasHiddenPanes(let tab): "\"\(tab)\" has a pane in an excluded folder or workspace, so Holler won't close it"
    case .noAgentNamed(let name): "no agent called \"\(name)\" is open"
    case .severalAgentsNamed(let name): "more than one agent is called \"\(name)\"; ask Holler for the one you mean"
    case .notWorking(let pane, "blocked"):
      "the agent in \(pane) is waiting on you in its terminal, so Holler won't interrupt it; answer it there"
    case .notWorking(let pane, let status): "the agent in \(pane) isn't working (it's \(status)), so there's nothing to interrupt"
    case .agentChanged(let pane): "\(pane) no longer holds the agent on the card, so Holler left it alone; ask again"
    case .agentBlocked(let pane):
      "the agent in \(pane) is waiting on you in its terminal, so Holler won't send it anything; answer it there"
    case .worktreeRefused(let reason): "can't start the agent in a new worktree: \(reason)"
    }
  }
}

/// What Holler may see in Herdr at one moment.
public struct HerdrState: Sendable, Equatable {
  public var agents: [HerdrAgent]
  public var workspaces: [HerdrWorkspace]
  /// Ids of the tabs Holler started that still have the agent it started in them.
  public var startedTabs: Set<String> = []
}

/// The agents Holler can start: a short allow-list of Herdr's kinds, so the
/// model can't pick one that isn't installed or hasn't been tried.
public enum AgentKind: String, Sendable, Equatable, CaseIterable {
  case claude
  case codex

  /// How the note names it: "Start Codex in demo / web".
  public var displayName: String {
    switch self {
    case .claude: "Claude"
    case .codex: "Codex"
    }
  }
}

/// An agent to start in a new tab, or in a new git worktree. The model's
/// requests go through `HerdrClient.checkNewAgent`, and `start(_:)` checks
/// again before running.
public struct NewAgent: Sendable, Equatable {
  public let kind: AgentKind
  public let workspace: HerdrWorkspace
  /// Absolute path of an existing folder the filter allows.
  public let folder: String
  public let tab: String
  /// The first message for the agent; nil starts it with nothing to do.
  public let task: String?
  /// Where the new checkout goes, when the agent starts in a worktree of
  /// `folder`'s repository instead of a tab in `workspace`.
  public let worktree: NewWorktree?

  public init(
    kind: AgentKind = .claude, workspace: HerdrWorkspace, folder: String, tab: String, task: String?,
    worktree: NewWorktree? = nil
  ) {
    self.kind = kind
    self.workspace = workspace
    self.folder = folder
    self.tab = tab
    self.task = task
    self.worktree = worktree
  }
}

/// A git worktree to make for a new agent. Herdr opens it as its own
/// workspace, linked to the repository's, labelled with the tab name.
public struct NewWorktree: Sendable, Equatable {
  /// The repository's name, e.g. "web".
  public let repository: String
  /// The new branch, named after the tab.
  public let branch: String
  /// Absolute path of the new checkout, which doesn't exist yet and isn't
  /// in an excluded folder.
  public let path: String

  public init(repository: String, branch: String, path: String) {
    self.repository = repository
    self.branch = branch
    self.path = path
  }
}

/// A tab Holler started, about to be closed. The model's requests go through
/// `HerdrClient.checkClose`, and `close(_:)` checks again before running.
public struct TabToClose: Sendable, Equatable {
  public struct Agent: Sendable, Equatable {
    public let agent: HerdrAgent
    /// The last line of its output, so the card shows what closing would end.
    public let lastLine: String?

    public init(agent: HerdrAgent, lastLine: String?) {
      self.agent = agent
      self.lastLine = lastLine
    }
  }

  public let tabId: String
  public let workspace: String
  public let tab: String
  /// Every agent in the tab; closing the tab stops them all.
  public let agents: [Agent]

  public init(tabId: String, workspace: String, tab: String, agents: [Agent]) {
    self.tabId = tabId
    self.workspace = workspace
    self.tab = tab
    self.agents = agents
  }
}

/// A working agent, about to be interrupted. The model's requests go through
/// `HerdrClient.checkInterrupt`, and `interrupt(_:)` checks again before running.
public struct AgentToInterrupt: Sendable, Equatable {
  public let agent: HerdrAgent
  /// The last line of its output, so the card shows what it would stop.
  public let lastLine: String?

  public init(agent: HerdrAgent, lastLine: String?) {
    self.agent = agent
    self.lastLine = lastLine
  }
}

/// A tab Holler started, and the agent it started there. Herdr never reuses a
/// tab id within one run, but starts its ids over when it restarts, so a saved
/// `w1:t3` alone could be someone else's tab. The agent's session id can't be,
/// nor can Herdr's terminal id, which starts with the time the terminal opened:
/// the tab is Holler's only while the ids recorded are still in the pane Holler
/// started it in.
struct StartedTab: Codable, Equatable, Sendable {
  let tabId: String
  let paneId: String
  /// Herdr's id for the pane's terminal, checked too when Herdr gave one.
  let terminalId: String?
  /// The agent's session id, checked too when Herdr knew it. Herdr gives none
  /// for Codex, or for Claude while it asks whether to trust the folder.
  let sessionId: String?

  /// Whether the tab could still hold the agent Holler started: the tab and
  /// its pane are open, and the pane's terminal is the one recorded, where
  /// both are known. Herdr restarts its ids, so a saved tab id can come to
  /// name someone else's tab; another terminal in the pane gives that away
  /// for good, whereas an agent Herdr can't see for a moment doesn't.
  func mayBeOpen(in snapshot: HerdrSnapshot) -> Bool {
    guard snapshot.tabs.contains(where: { $0.tab_id == tabId }) else { return false }
    guard let terminal = snapshot.terminalId(inPane: paneId) else {
      // The pane has closed, unless this Herdr doesn't list panes at all.
      return snapshot.panes.isEmpty
    }
    if let recorded = terminalId, let current = terminal, current != recorded { return false }
    return true
  }

  /// Whether the agent Holler started is still in its pane, in its tab. A tab
  /// with neither id recorded never is.
  func isOpen(in snapshot: HerdrSnapshot) -> Bool {
    guard sessionId != nil || terminalId != nil else { return false }
    return snapshot.agents.contains { agent in
      agent.pane_id == paneId && agent.tab_id == tabId
        && (sessionId == nil || agent.sessionId == sessionId)
        && (terminalId == nil || agent.terminalId == terminalId)
    }
  }
}

/// The filter a client and its copies share, so a reload can change it.
final class SharedFilter: Sendable {
  private let filter: Mutex<AgentFilter>

  init(_ filter: AgentFilter) {
    self.filter = Mutex(filter)
  }

  var value: AgentFilter {
    get { filter.withLock { $0 } }
    set { filter.withLock { $0 = newValue } }
  }
}

/// The tabs Holler has started, shared by every copy of a client, and kept in
/// `file` when there is one, so they're still Holler's to close after it
/// restarts.
final class StartedTabs: Sendable {
  private let file: URL?
  private let tabs: Mutex<[StartedTab]>

  init(file: URL?) {
    self.file = file
    tabs = Mutex(
      file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([StartedTab].self, from: $0) } ?? [])
  }

  func insert(_ tab: StartedTab) {
    tabs.withLock { tabs in
      tabs.removeAll { $0.tabId == tab.tabId }
      tabs.append(tab)
      save(tabs)
    }
  }

  func remove(_ tabId: String) {
    tabs.withLock { tabs in
      tabs.removeAll { $0.tabId == tabId }
      save(tabs)
    }
  }

  /// Ids of the tabs still Holler's in `snapshot`. A tab that has closed, or
  /// whose pane now holds another terminal, is forgotten. One without its
  /// agent right now is kept but doesn't count, so a moment when Herdr can't
  /// see the agent doesn't lose the tab.
  func open(in snapshot: HerdrSnapshot) -> Set<String> {
    tabs.withLock { tabs in
      let existing = tabs.filter { $0.mayBeOpen(in: snapshot) }
      if existing != tabs {
        tabs = existing
        save(tabs)
      }
      return Set(existing.filter { $0.isOpen(in: snapshot) }.map(\.tabId))
    }
  }

  /// Called with the lock held, so writes happen in order. A tab that can't
  /// be saved is still Holler's until it quits.
  private func save(_ tabs: [StartedTab]) {
    guard let file, let data = try? JSONEncoder().encode(tabs) else { return }
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
  }
}

/// The only way the app touches Herdr. Every read, prompt, interrupt or jump resolves its pane
/// against a fresh snapshot first, so a closed, filtered-out or invented pane id
/// fails here rather than reaching `herdr`. Starting an agent re-checks its
/// workspace and folder the same way, and only a tab Holler started, with the
/// agent it started still in it, can be closed.
public struct HerdrClient: Sendable {
  /// Enough for the whole scrollback of one pane: the longest measured was
  /// 812 lines. Herdr serves a scrollback read in about 2 s.
  public static let maxReadLines = 2_000
  public static let maxMessageLength = 2_000
  public static let maxTabLabelLength = 40

  let executable: URL
  let runner: any CommandRunning
  /// Shared by every copy of the client, so a reload reaches them all.
  private let sharedFilter: SharedFilter
  var filter: AgentFilter { sharedFilter.value }
  let startedTabs: StartedTabs
  /// Where new worktrees go, one folder per repository.
  let worktreesDirectory: String

  /// `startedTabsFile` keeps the tabs Holler started across restarts; without
  /// one they're forgotten when it quits. `worktreesDirectory` defaults to
  /// the one set in Herdr's config, or Herdr's own default.
  public init(
    executable: URL, runner: any CommandRunning = ProcessRunner(), filter: AgentFilter = AgentFilter(),
    startedTabsFile: URL? = nil, worktreesDirectory: String? = nil
  ) {
    self.executable = executable
    self.runner = runner
    sharedFilter = SharedFilter(filter)
    startedTabs = StartedTabs(file: startedTabsFile)
    self.worktreesDirectory = ((worktreesDirectory ?? Self.configuredWorktreesDirectory()) as NSString).expandingTildeInPath
  }

  /// Changes which agents Holler may see, for this client and every copy of
  /// it, from the next snapshot on.
  public func update(filter: AgentFilter) {
    sharedFilter.value = filter
  }

  /// A GUI app doesn't inherit the shell's PATH, so look in the usual install
  /// locations rather than relying on `herdr` resolving.
  public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
    let home = environment["HOME"] ?? NSHomeDirectory()
    let candidates = [
      environment["HERDR_PATH"],
      "\(home)/.local/bin/herdr",
      "/opt/homebrew/bin/herdr",
      "/usr/local/bin/herdr",
    ].compactMap { $0 }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
  }

  // MARK: - Commands

  /// Every agent and workspace Herdr knows about that the filter allows.
  public func state() async throws -> HerdrState {
    let snapshot = try await snapshot()
    let workspaces = snapshot.workspaceList(allowing: filter)
    return HerdrState(
      agents: snapshot.flattened.filter(filter.allows), workspaces: workspaces, startedTabs: startedTabs.open(in: snapshot))
  }

  public func agents() async throws -> [HerdrAgent] {
    try await state().agents
  }

  /// The agent's last `lines` lines, back into its scrollback, kept to the
  /// last `maxCharacters` with a first line saying what's missing: how much
  /// was cut, or that only the screen could be read. The budget belongs to
  /// the read, so a read of a whole conversation can ask for more without
  /// the screen reads that go with every request growing.
  public func read(
    paneId: String, lines: Int, maxCharacters: Int = PaneText.maxCharacters
  ) async throws -> (agent: HerdrAgent, text: String) {
    let agent = try await resolve(paneId)
    return (agent, try await read(agent, lines: lines, maxCharacters: maxCharacters))
  }

  /// Reads an agent taken from `agents()`, skipping the re-resolve. The filter
  /// was applied when that list was built, so nothing filtered out can get here.
  public func read(_ agent: HerdrAgent, lines: Int, maxCharacters: Int = PaneText.maxCharacters) async throws -> String {
    // A working agent's scrollback can't be captured, only what is on screen.
    // That is usually the most useful part anyway: what it is doing right now.
    // Herdr would refuse the scrollback read, so don't pay for the attempt.
    guard agent.status != "working" else { return try await markedScreen(agent, lines: lines, maxCharacters: maxCharacters) }
    do {
      let output = try await herdr(Self.readArguments(paneId: agent.paneId, lines: lines), timeout: Self.readTimeout(lines: lines))
      return Self.paneText(output, maxCharacters: maxCharacters)
    } catch HerdrError.commandFailed(_, let detail) where detail.contains("agent_not_idle") {
      // The snapshot was stale and the agent has since started working.
      return try await markedScreen(agent, lines: lines, maxCharacters: maxCharacters)
    } catch CommandError.timedOut {
      // Herdr scrolls the pane back through its history for this read and
      // didn't finish in time: the screen, which it serves at once, is better
      // than nothing, with a marker so the model can say why.
      return PaneText.readTimedOut + "\n" + (try await readScreen(agent, lines: lines, maxCharacters: maxCharacters))
    }
  }

  /// How long a scrollback read may take: Herdr scrolls an idle agent's pane
  /// back through its history, so the time grows with the lines asked for.
  /// Measured on 2026-11-04: 1.5 s for 400 lines and 4 s for 2,000 on an
  /// 820-line tab with Herdr otherwise idle, and past 5 s inside the app, with
  /// the screen reads of nine other panes alongside it. 5 s for a card's 40
  /// lines, 25 s for a whole scrollback.
  static func readTimeout(lines: Int) -> Duration {
    .seconds(5 + clamped(lines) / 100)
  }

  /// The lines a read may ask for: the model names the number, so it can be
  /// anything.
  private static func clamped(_ lines: Int) -> Int {
    min(max(lines, 1), maxReadLines)
  }

  /// The screen in place of the scrollback asked for, saying so first.
  private func markedScreen(_ agent: HerdrAgent, lines: Int, maxCharacters: Int) async throws -> String {
    PaneText.screenOnly + "\n" + (try await readScreen(agent, lines: lines, maxCharacters: maxCharacters))
  }

  /// What is on the agent's screen, at most its last `lines` rows. About 10 ms
  /// whatever the agent is doing, where reading back into scrollback costs
  /// 250 ms or more.
  public func readScreen(_ agent: HerdrAgent, lines: Int, maxCharacters: Int = PaneText.maxCharacters) async throws -> String {
    let arguments = Self.readArguments(paneId: agent.paneId, lines: lines, source: "visible")
    return Self.paneText(try await herdr(arguments, timeout: .seconds(5)), maxCharacters: maxCharacters)
  }

  /// The only path from a raw screen to text anyone sees: every pane read, in
  /// the app and the CLI, comes through here. Secrets are redacted before the
  /// text is cut to size, so a key's tail can't survive the cut.
  static func paneText(_ raw: String, maxCharacters: Int = PaneText.maxCharacters) -> String {
    PaneText.clean(Redaction.redact(raw), maxCharacters: maxCharacters)
  }

  /// Submits `message` to `expected`, the agent its card names, as if typed
  /// at its prompt. The pane is looked up again first, so an agent that has
  /// closed, been filtered out or been replaced by another in the same pane
  /// is never sent it. Nor is a blocked agent, one waiting on an approval
  /// or a question: Herdr rejects that itself, and Holler doesn't lean on
  /// it, so a message can never answer a permission prompt on the user's
  /// behalf.
  @discardableResult
  public func prompt(_ expected: HerdrAgent, message: String) async throws -> HerdrAgent {
    let text = try Self.sanitize(message)
    let agent = try await still(expected)
    guard agent.status != "blocked" else { throw HerdrError.agentBlocked(paneId: agent.paneId) }
    _ = try await herdr(Self.promptArguments(paneId: agent.paneId, message: text), timeout: .seconds(10))
    return agent
  }

  /// Shows the agent in Herdr: switches to its tab and focuses its pane. It
  /// only moves the user's view; nothing reaches the agent, though Herdr marks
  /// a finished one as seen.
  @discardableResult
  public func focus(paneId: String) async throws -> HerdrAgent {
    let agent = try await resolve(paneId)
    _ = try await herdr(Self.focusArguments(paneId: agent.paneId), timeout: .seconds(5))
    return agent
  }

  /// Shows the agent a summary names, "demo / api", found by its workspace
  /// and tab in a fresh snapshot, ignoring case. A name that fits no agent
  /// Holler can see, or more than one, isn't guessed at.
  @discardableResult
  public func focus(workspace: String?, tab: String) async throws -> HerdrAgent {
    func same(_ a: String, _ b: String) -> Bool {
      a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }
    let name = workspace.map { "\($0) / \(tab)" } ?? tab
    let matches = try await agents().filter { agent in
      same(agent.tab, tab) && (workspace.map { same(agent.workspace, $0) } ?? true)
    }
    guard let agent = matches.first else { throw HerdrError.noAgentNamed(name) }
    guard matches.count == 1 else { throw HerdrError.severalAgentsNamed(name) }
    _ = try await herdr(Self.focusArguments(paneId: agent.paneId), timeout: .seconds(5))
    return agent
  }

  /// Validates a requested start without running anything: the workspace is
  /// open and allowed, the folder exists and isn't excluded, and the kind is
  /// one Holler can start. No kind means Claude. A start in a worktree also
  /// needs the new checkout's path and workspace to be ones Holler may see.
  public func checkNewAgent(
    kind: String? = nil, workspace: String, folder: String, tab: String, task: String?, worktree: Bool = false
  ) async throws -> NewAgent {
    let requested = (kind ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    guard let agentKind = requested.isEmpty ? .claude : AgentKind(rawValue: requested) else {
      throw HerdrError.unknownAgentKind(requested)
    }
    let label = try Self.tabLabel(tab)
    let task = try task.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try Self.sanitize($0) }
    let path = try checkFolder(folder)
    let workspaces = try await state().workspaces
    guard
      let match = workspaces.first(where: { $0.id == workspace })
        ?? workspaces.first(where: { $0.label.caseInsensitiveCompare(workspace) == .orderedSame })
    else { throw HerdrError.unknownWorkspace(workspace) }
    let checkout = worktree ? try await checkWorktree(of: path, label: label) : nil
    return NewAgent(kind: agentKind, workspace: match, folder: path, tab: label, task: task, worktree: checkout)
  }

  /// Opens a tab, or a worktree in its own workspace, starts the agent in it
  /// and, if there is one, gives it its task. Herdr waits for the agent to be
  /// ready for input before `agent start` returns, so the task can follow
  /// straight away.
  public func start(_ request: NewAgent) async throws -> HerdrAgent {
    let new = try await checkNewAgent(
      kind: request.kind.rawValue, workspace: request.workspace.id, folder: request.folder, tab: request.tab, task: request.task,
      worktree: request.worktree != nil)
    guard new.worktree == request.worktree else {
      throw HerdrError.worktreeRefused("\(request.worktree?.path ?? "the checkout") was taken after the card was shown")
    }
    let opened = try await open(new)

    do {
      try await startAgent(new.kind, in: opened.paneId, name: Self.agentName(new.tab))
    } catch HerdrError.commandFailed(_, let detail) where detail.contains("agent_not_ready") {
      // Left open: the question is the user's to answer in that tab.
      await remember(tabId: opened.tabId, paneId: opened.paneId)
      throw HerdrError.startupBlocked(paneId: opened.paneId)
    } catch {
      await closeOpened(opened)
      throw error
    }
    await remember(tabId: opened.tabId, paneId: opened.paneId)
    let paneId = opened.paneId

    if let task = new.task {
      do {
        _ = try await herdr(Self.promptArguments(paneId: paneId, message: task), timeout: .seconds(10))
      } catch {
        throw HerdrError.taskNotSent(paneId: paneId, detail: "\(error)")
      }
    }
    return HerdrAgent(
      paneId: paneId, kind: new.kind.rawValue, status: new.task == nil ? "idle" : "working",
      workspace: opened.workspace, tab: opened.tab, tabId: opened.tabId, cwd: opened.folder, title: "", focused: false)
  }

  /// Validates closing the tab `paneId` is in, without closing anything, and
  /// reads each of its agents' last line for the card.
  public func checkClose(paneId: String) async throws -> TabToClose {
    let snapshot = try await snapshot()
    guard let agent = snapshot.flattened.first(where: { $0.paneId == paneId && filter.allows($0) }) else {
      throw HerdrError.unknownPane(paneId)
    }
    let tab = try closable(agent.tabId, in: snapshot)
    let agents = await withTaskGroup(of: (Int, TabToClose.Agent).self) { group in
      for (index, closing) in tab.agents.enumerated() {
        group.addTask {
          let text = try? await read(closing.agent, lines: 40)
          return (index, TabToClose.Agent(agent: closing.agent, lastLine: text.flatMap { PaneText.lastLine($0) }))
        }
      }
      var collected: [(Int, TabToClose.Agent)] = []
      for await result in group { collected.append(result) }
      return collected.sorted { $0.0 < $1.0 }.map(\.1)
    }
    return TabToClose(tabId: tab.tabId, workspace: tab.workspace, tab: tab.tab, agents: agents)
  }

  /// Closes a tab Holler started, stopping every agent in it, whatever it is
  /// doing. The tab is checked again first, so one that has closed, been
  /// filtered out or wasn't started here is never touched.
  @discardableResult
  public func close(_ request: TabToClose) async throws -> TabToClose {
    let tab = try closable(request.tabId, in: try await snapshot())
    _ = try await herdr(Self.tabCloseArguments(tabId: tab.tabId), timeout: .seconds(5))
    startedTabs.remove(tab.tabId)
    return tab
  }

  /// Validates interrupting the agent in `paneId`, without sending anything:
  /// Holler can see it and it is working. Reads its last line for the card.
  /// Any agent can be interrupted, not only one in a tab Holler started.
  public func checkInterrupt(paneId: String) async throws -> AgentToInterrupt {
    let agent = try interruptible(try await resolve(paneId))
    let text = try? await read(agent, lines: 40)
    return AgentToInterrupt(agent: agent, lastLine: text.flatMap { PaneText.lastLine($0) })
  }

  /// Sends Esc to a working agent, which stops what it is doing and leaves it
  /// at its prompt. The pane is checked again first, so an agent that has
  /// closed, been filtered out, stopped working or been replaced by another
  /// in the same pane (another terminal, tab or kind of agent) is never sent
  /// it. Esc is never sent to a blocked agent, where it would dismiss the
  /// approval or question it is waiting on.
  @discardableResult
  public func interrupt(_ request: AgentToInterrupt) async throws -> HerdrAgent {
    let agent = try await still(request.agent)
    guard agent.kind == request.agent.kind else { throw HerdrError.agentChanged(agent.paneId) }
    _ = try await herdr(Self.sendKeysArguments(paneId: try interruptible(agent).paneId, keys: ["esc"]), timeout: .seconds(5))
    return agent
  }

  /// The agent a card names, as a fresh snapshot has it: still one Holler
  /// can see, in the pane, terminal, tab and workspace the card was made for.
  private func still(_ expected: HerdrAgent) async throws -> HerdrAgent {
    let agent = try await resolve(expected.paneId)
    guard expected.isStill(agent) else { throw HerdrError.agentChanged(agent.paneId) }
    return agent
  }

  public func resolve(_ paneId: String) async throws -> HerdrAgent {
    guard let agent = try await agents().first(where: { $0.paneId == paneId }) else {
      throw HerdrError.unknownPane(paneId)
    }
    return agent
  }

  // MARK: - Argv

  static func snapshotArguments() -> [String] {
    ["api", "snapshot"]
  }

  static func readArguments(paneId: String, lines: Int, source: String = "recent-unwrapped") -> [String] {
    ["agent", "read", paneId, "--source", source, "--format", "text", "--lines", String(clamped(lines))]
  }

  static func promptArguments(paneId: String, message: String) -> [String] {
    ["agent", "prompt", paneId, message]
  }

  static func sendKeysArguments(paneId: String, keys: [String]) -> [String] {
    ["agent", "send-keys", paneId] + keys
  }

  static func focusArguments(paneId: String) -> [String] {
    ["agent", "focus", paneId]
  }

  static func tabCreateArguments(workspaceId: String, folder: String, label: String) -> [String] {
    ["tab", "create", "--workspace", workspaceId, "--cwd", folder, "--label", label, "--no-focus"]
  }

  static func tabCloseArguments(tabId: String) -> [String] {
    ["tab", "close", tabId]
  }

  static func worktreeListArguments(folder: String) -> [String] {
    ["worktree", "list", "--cwd", folder]
  }

  /// Never `--trust-repository`: whether to trust a repository is the user's
  /// call, in Herdr, so Holler passes on Herdr's refusal instead.
  static func worktreeCreateArguments(folder: String, worktree: NewWorktree, label: String) -> [String] {
    ["worktree", "create", "--cwd", folder, "--branch", worktree.branch, "--path", worktree.path, "--label", label, "--no-focus"]
  }

  static func workspaceCloseArguments(workspaceId: String) -> [String] {
    ["workspace", "close", workspaceId]
  }

  static func agentStartArguments(kind: AgentKind, name: String, paneId: String) -> [String] {
    ["agent", "start", name, "--kind", kind.rawValue, "--pane", paneId, "--timeout", "30000"]
  }

  /// Herdr agent names must be unique, so this is only the first one tried.
  static func agentName(_ tab: String) -> String {
    let slug = String(tab.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
      .split(separator: "-").joined(separator: "-")
    return slug.isEmpty ? "agent" : String(slug.prefix(30))
  }

  static func tabLabel(_ label: String) throws -> String {
    let cleaned = String(label.map { $0.isControlCharacter || $0.isNewline ? " " : $0 })
      .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    guard !cleaned.isEmpty else { throw HerdrError.invalidMessage("the tab needs a name") }
    // `herdr` would read it as one of its own options, not as the name.
    guard !cleaned.hasPrefix("-") else { throw HerdrError.invalidMessage("a tab name can't start with a dash") }
    guard cleaned.count <= maxTabLabelLength else {
      throw HerdrError.invalidMessage("tab name longer than \(maxTabLabelLength) characters")
    }
    return cleaned
  }

  /// Strips control characters (escape sequences could drive the agent's TUI)
  /// while keeping newlines and tabs, and bounds the length.
  static func sanitize(_ message: String) throws -> String {
    let allowed: Set<Character> = ["\n", "\t"]
    let cleaned = String(message.filter { allowed.contains($0) || !$0.isControlCharacter })
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { throw HerdrError.invalidMessage("empty") }
    guard cleaned.count <= maxMessageLength else {
      throw HerdrError.invalidMessage("longer than \(maxMessageLength) characters")
    }
    return cleaned
  }

  // MARK: - Private

  /// What `tab create` and `worktree create` both answer with; a worktree
  /// adds the workspace Herdr opened for it and where the checkout went.
  private struct TabCreated: Decodable {
    struct Result: Decodable {
      struct Pane: Decodable { let pane_id: String }
      struct Tab: Decodable {
        let tab_id: String
        let label: String?
      }
      struct Workspace: Decodable {
        let workspace_id: String
        let label: String
      }
      struct Worktree: Decodable { let path: String }
      let root_pane: Pane
      let tab: Tab
      let workspace: Workspace?
      let worktree: Worktree?
    }
    let result: Result
  }

  private struct WorktreeList: Decodable {
    struct Result: Decodable {
      struct Source: Decodable {
        let repo_name: String
        let repo_root: String
      }
      struct Worktree: Decodable {
        let path: String
        let branch: String?
      }
      let source: Source
      let worktrees: [Worktree]
    }
    let result: Result
  }

  /// Where a new agent goes once its tab or worktree is open.
  private struct Opened {
    let paneId: String
    let tabId: String
    let tab: String
    let workspace: String
    /// Set for a worktree, whose workspace Holler opened and closes again if
    /// the agent fails to start.
    let workspaceId: String?
    let folder: String
  }

  /// Opens the new agent's tab, or its worktree. A worktree whose checkout or
  /// workspace turns out to be one Holler can't see is closed again at once.
  private func open(_ new: NewAgent) async throws -> Opened {
    guard let worktree = new.worktree else {
      let created = try await herdr(
        Self.tabCreateArguments(workspaceId: new.workspace.id, folder: new.folder, label: new.tab), timeout: .seconds(5))
      guard let tab = try? JSONDecoder().decode(TabCreated.self, from: Data(created.utf8)).result else {
        throw HerdrError.unparseable("tab create: \(created.prefix(200))")
      }
      return Opened(
        paneId: tab.root_pane.pane_id, tabId: tab.tab.tab_id, tab: new.tab, workspace: new.workspace.label, workspaceId: nil,
        folder: new.folder)
    }
    let created: String
    do {
      created = try await herdr(
        Self.worktreeCreateArguments(folder: new.folder, worktree: worktree, label: new.tab), timeout: .seconds(30))
    } catch HerdrError.commandFailed(_, let detail) {
      throw HerdrError.worktreeRefused(Self.herdrMessage(detail))
    }
    guard let result = try? JSONDecoder().decode(TabCreated.self, from: Data(created.utf8)).result,
      let workspace = result.workspace
    else { throw HerdrError.unparseable("worktree create: \(created.prefix(200))") }
    let opened = Opened(
      paneId: result.root_pane.pane_id, tabId: result.tab.tab_id, tab: result.tab.label ?? new.tab,
      workspace: workspace.label, workspaceId: workspace.workspace_id, folder: result.worktree?.path ?? worktree.path)
    guard filter.allowsFolder(opened.folder), filter.allowsWorkspace(opened.workspace) else {
      await closeOpened(opened)
      throw HerdrError.worktreeRefused(
        "Herdr opened it as \"\(opened.workspace)\" at \(opened.folder), which Holler can't see, so it closed it again")
    }
    return opened
  }

  /// Closes what `open` opened, after the agent failed to start in it. A
  /// worktree's checkout and branch stay on disk; only its workspace closes.
  private func closeOpened(_ opened: Opened) async {
    let arguments =
      opened.workspaceId.map { Self.workspaceCloseArguments(workspaceId: $0) } ?? Self.tabCloseArguments(tabId: opened.tabId)
    _ = try? await herdr(arguments, timeout: .seconds(5))
  }

  /// Where a worktree of `folder`'s repository would go, named after the
  /// tab. Herdr reads the repository, so one it doesn't trust or that isn't a
  /// git repository fails here, before any card is shown. The repository
  /// mustn't hold an excluded folder, which a worktree would copy somewhere
  /// Holler can see, and the new workspace must be one the filter allows.
  private func checkWorktree(of folder: String, label: String) async throws -> NewWorktree {
    guard filter.allowsWorkspace(label) else {
      throw HerdrError.worktreeRefused(
        "it opens as its own workspace, \"\(label)\", and Holler only sees " + filter.workspaces.joined(separator: ", "))
    }
    let output: String
    do {
      output = try await herdr(Self.worktreeListArguments(folder: folder), timeout: .seconds(10))
    } catch HerdrError.commandFailed(_, let detail) {
      throw HerdrError.worktreeRefused(Self.herdrMessage(detail))
    }
    guard let list = try? JSONDecoder().decode(WorktreeList.self, from: Data(output.utf8)).result else {
      throw HerdrError.unparseable("worktree list: \(output.prefix(200))")
    }
    if !filter.allowsFolder(list.source.repo_root) || filter.excludesFolder(inside: list.source.repo_root) {
      throw HerdrError.worktreeRefused("the repository has a folder excluded from Holler in it")
    }

    let repository = list.source.repo_name
    let parent = URL(fileURLWithPath: worktreesDirectory).appendingPathComponent(repository)
    let branch = Self.agentName(label)
    let candidates = [branch] + (2...5).map { "\(branch)-\($0)" }
    guard
      let free = candidates.first(where: { candidate in
        let path = parent.appendingPathComponent(candidate).path
        return !FileManager.default.fileExists(atPath: path)
          && !list.worktrees.contains { $0.path == path || $0.branch == candidate }
      })
    else { throw HerdrError.worktreeRefused("\(parent.path) already has worktrees called \(branch) to \(branch)-5") }
    let path = parent.appendingPathComponent(free).path
    guard filter.allowsFolder(path) else { throw HerdrError.worktreeRefused("\(path) is in a folder excluded from Holler") }
    return NewWorktree(repository: repository, branch: free, path: path)
  }

  /// Herdr's own words from a failed command's JSON error, or the detail as
  /// it came.
  static func herdrMessage(_ detail: String) -> String {
    struct Failure: Decodable {
      struct Body: Decodable { let message: String }
      let error: Body
    }
    guard let failure = try? JSONDecoder().decode(Failure.self, from: Data(detail.utf8)), !failure.error.message.isEmpty else {
      return detail
    }
    return failure.error.message
  }

  /// The `directory` under `[worktrees]` in Herdr's config, or Herdr's default.
  static func configuredWorktreesDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    let home = environment["HOME"] ?? NSHomeDirectory()
    let config = URL(fileURLWithPath: environment["XDG_CONFIG_HOME"] ?? "\(home)/.config")
      .appendingPathComponent("herdr/config.toml")
    let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
    return worktreesDirectory(config: text) ?? "~/.herdr/worktrees"
  }

  static func worktreesDirectory(config: String) -> String? {
    var section = ""
    for line in config.split(whereSeparator: \.isNewline) {
      let text = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .trimmingCharacters(in: .whitespaces)
      if text.hasPrefix("[") {
        section = text
        continue
      }
      let pair = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard section == "[worktrees]", pair.count == 2, pair[0] == "directory" else { continue }
      let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      return value.isEmpty ? nil : value
    }
    return nil
  }

  private func snapshot() async throws -> HerdrSnapshot {
    let output = try await herdr(Self.snapshotArguments(), timeout: .seconds(5))
    do {
      return try HerdrSnapshot.decode(output)
    } catch {
      throw HerdrError.unparseable("api snapshot: \(error)")
    }
  }

  /// Records the new tab as Holler's, with its agent's session id and
  /// terminal id. Herdr gives no session for Codex, or while Claude asks
  /// whether to trust the folder; then the terminal id alone tells the tab
  /// apart from one with the same id after Herdr restarts, and a session that
  /// turns up later isn't needed. A tab with neither isn't recorded.
  private func remember(tabId: String, paneId: String) async {
    guard let snapshot = try? await snapshot(),
      let agent = snapshot.agents.first(where: { $0.pane_id == paneId && $0.tab_id == tabId }),
      agent.sessionId != nil || agent.terminalId != nil
    else { return }
    startedTabs.insert(StartedTab(tabId: tabId, paneId: paneId, terminalId: agent.terminalId, sessionId: agent.sessionId))
  }

  /// The tab, if Holler may close it: still open, started by Holler with that
  /// agent still in it, and with no pane the filter hides. Checks the
  /// unfiltered snapshot, because a hidden pane in the tab is exactly what
  /// must stop the close.
  private func closable(_ tabId: String, in snapshot: HerdrSnapshot) throws -> TabToClose {
    guard let tab = snapshot.tabs.first(where: { $0.tab_id == tabId }) else { throw HerdrError.unknownTab(tabId) }
    let label = tab.name
    guard startedTabs.open(in: snapshot).contains(tabId) else { throw HerdrError.notStartedByHoller(tab: label) }
    let workspace = snapshot.workspaces.first { $0.workspace_id == tab.workspace_id }
    let workspaceLabel = workspace?.label ?? tab.workspace_id ?? ""
    let agents = snapshot.flattened.filter { $0.tabId == tabId }
    let folders = snapshot.panes.filter { $0.tab_id == tabId }.compactMap(\.cwd) + agents.map(\.cwd)
    guard filter.allowsWorkspace(workspaceLabel), folders.allSatisfy(filter.allowsFolder) else {
      throw HerdrError.tabHasHiddenPanes(tab: label)
    }
    return TabToClose(
      tabId: tabId, workspace: workspaceLabel, tab: label, agents: agents.map { .init(agent: $0, lastLine: nil) })
  }

  /// The agent, if it is working: the only state where Esc interrupts
  /// rather than answers something.
  private func interruptible(_ agent: HerdrAgent) throws -> HerdrAgent {
    guard agent.status == "working" else { throw HerdrError.notWorking(paneId: agent.paneId, status: agent.status) }
    return agent
  }

  private func startAgent(_ kind: AgentKind, in paneId: String, name: String) async throws {
    for attempt in 1...5 {
      let candidate = attempt == 1 ? name : "\(name)-\(attempt)"
      do {
        _ = try await herdr(Self.agentStartArguments(kind: kind, name: candidate, paneId: paneId), timeout: .seconds(40))
        return
      } catch HerdrError.commandFailed(_, let detail) where detail.contains("agent_name_taken") && attempt < 5 {
        continue
      }
    }
  }

  /// An absolute path to an existing folder the filter allows. Symlinks and
  /// `..` are resolved before the check, so neither can reach an excluded folder.
  private func checkFolder(_ folder: String) throws -> String {
    let expanded = (folder.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else { throw HerdrError.invalidFolder(folder, reason: "not an absolute path") }
    let url = URL(fileURLWithPath: expanded).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw HerdrError.invalidFolder(folder, reason: "no such folder")
    }
    guard filter.allowsFolder(url.path) else {
      throw HerdrError.invalidFolder(folder, reason: "that folder is excluded from Holler")
    }
    return url.path
  }

  private func herdr(_ arguments: [String], timeout: Duration) async throws -> String {
    let result = try await runner.run(executable, arguments, timeout: timeout)
    guard result.exitCode == 0 else {
      let detail = [result.stderr, result.stdout]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "exit \(result.exitCode)"
      throw HerdrError.commandFailed(command: arguments.prefix(2).joined(separator: " "), detail: detail)
    }
    return result.stdout
  }
}

extension Character {
  fileprivate var isControlCharacter: Bool {
    unicodeScalars.contains { $0.properties.generalCategory == .control }
  }
}
