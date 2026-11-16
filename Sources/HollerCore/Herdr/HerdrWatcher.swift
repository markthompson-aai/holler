import Foundation

/// A live picture of the agents Holler may see: each one's status, when it
/// last started or stopped working, and the changes since Holler began
/// watching. Herdr doesn't timestamp states, so Holler times them itself from
/// Herdr's event stream. The snapshots each request takes are passed in too,
/// and catch up on anything the stream missed, timed when Holler noticed; with
/// the stream down, or no stream at all, they're all it has, as before.
///
/// With a `file`, the picture is kept on disk and loaded on the next launch,
/// so wait times and "what changed since I last asked" carry on after Holler
/// relaunches; whatever happened while it was off is caught up from the first
/// snapshot, as having happened by then.
///
/// It only ever subscribes and reads, and only sees the agents the client's
/// filter allows.
public actor HerdrWatcher {
  /// When an agent last started or stopped working.
  public struct Since: Sendable, Equatable {
    public let date: Date
    /// False when Holler only knows it was so by `date`: it began before
    /// Holler was watching, or while the event stream was down.
    public let exact: Bool

    public init(date: Date, exact: Bool) {
      self.date = date
      self.exact = exact
    }
  }

  public struct Change: Sendable, Equatable {
    public let paneId: String
    /// "workspace / tab", so an agent that has closed can still be named.
    public let name: String
    /// Nil when the agent appeared.
    public let from: String?
    /// Nil when it closed.
    public let to: String?
    public let at: Date
    /// False when it happened by `at`, rather than at it.
    public let exact: Bool

    public init(paneId: String, name: String, from: String?, to: String?, at: Date, exact: Bool) {
      self.paneId = paneId
      self.name = name
      self.from = from
      self.to = to
      self.at = at
      self.exact = exact
    }
  }

  /// A point in the watcher's history; the changes after it are new.
  public struct Mark: Sendable, Equatable, Codable {
    let sequence: Int
    public let date: Date
  }

  /// The watcher as one request sees it.
  public struct Picture: Sendable, Equatable {
    public let mark: Mark
    public let since: [String: Since]
    /// The changes after the mark the request asked about, oldest first.
    public let changes: [Change]
    public let isLive: Bool
  }

  private struct Watched {
    var name: String
    var status: String
    var since: Since
    /// Herdr's id for the pane's terminal, when it gave one. A pane whose
    /// terminal id has changed holds a new agent: Herdr restarted and gave
    /// its pane id again.
    var terminalId: String?
  }

  /// The history file. Dates are seconds since 1970.
  private struct Saved: Codable {
    struct Agent: Codable {
      var paneId: String
      var terminalId: String?
      var name: String
      var status: String
      var since: Date
      var exact: Bool
    }

    struct Change: Codable {
      var sequence: Int
      var paneId: String
      var name: String
      var from: String?
      var to: String?
      var at: Date
      var exact: Bool
    }

    var version = 1
    var sequence: Int
    var lastAsked: Mark?
    var agents: [Agent]
    var changes: [Change]

    /// Nil for a file that's missing or can't be read as a history.
    static func load(_ file: URL) -> Saved? {
      guard let data = try? Data(contentsOf: file) else { return nil }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .secondsSince1970
      return try? decoder.decode(Saved.self, from: data)
    }

    func write(to file: URL) {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .secondsSince1970
      encoder.outputFormatting = .sortedKeys
      guard let data = try? encoder.encode(self) else { return }
      try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: file, options: .atomic)
    }
  }

  /// How many changes are kept; older ones are forgotten first.
  private static let historyLimit = 500

  private let herdr: HerdrClient
  private let source: (any HerdrEventSource)?
  private let file: URL?
  private let now: @Sendable () -> Date
  private let retryDelays: [Duration]
  private let settle: Duration

  private var watched: [String: Watched] = [:]
  private var history: [(sequence: Int, change: Change)] = []
  private var sequence = 0
  /// The mark of the last request that went through, kept with the history,
  /// so "what changed since I last asked" starts there even after a relaunch.
  public private(set) var lastAsked: Mark?
  /// False until the first look, whose agents were all there before watching began.
  private var seeded = false
  /// Whether the picture has changed since the file was last written.
  private var unsaved = false
  /// Whether events are coming in, so changes are timed as they happen.
  public private(set) var isLive = false
  private var loop: Task<Void, Never>?
  /// Who follows the count of agents that need you.
  private var countFollowers = Followers<Int>()
  /// The count the followers last heard, so they hear only of a change.
  private var lastCount = 0
  /// Who follows the changes as they're logged.
  private var changeFollowers = Followers<Change>()

  /// `file` keeps the picture across relaunches; without one it's forgotten
  /// when Holler quits. `retryDelays` space out attempts to reconnect after
  /// the stream drops or can't start, the last one repeating; `settle` lets a
  /// burst of panes opening or closing pass before subscribing again.
  public init(
    herdr: HerdrClient, source: (any HerdrEventSource)?, file: URL? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)],
    settle: Duration = .milliseconds(300)
  ) {
    self.herdr = herdr
    self.source = source
    self.file = file
    self.now = now
    self.retryDelays = retryDelays.isEmpty ? [.seconds(60)] : retryDelays
    self.settle = settle
    if let saved = file.flatMap(Saved.load) {
      watched = Dictionary(
        saved.agents.map {
          ($0.paneId, Watched(name: $0.name, status: $0.status, since: Since(date: $0.since, exact: $0.exact), terminalId: $0.terminalId))
        }, uniquingKeysWith: { _, last in last })
      history = saved.changes.suffix(Self.historyLimit).map {
        ($0.sequence, Change(paneId: $0.paneId, name: $0.name, from: $0.from, to: $0.to, at: $0.at, exact: $0.exact))
      }
      sequence = max(saved.sequence, history.last?.sequence ?? 0)
      lastAsked = saved.lastAsked
      lastCount = watched.values.count { Self.needsYou($0.status) }
      // The saved agents were watched, so one missing from the next look has closed.
      seeded = true
    }
  }

  /// Whether an agent with `status` needs you: Herdr reports it blocked,
  /// waiting for an answer or an approval in its terminal.
  static func needsYou(_ status: String) -> Bool { status == "blocked" }

  /// How many of the agents it watches need you. Only agents the filter
  /// allows are ever watched, so hidden ones aren't counted.
  public var needsYouCount: Int { watched.values.count { Self.needsYou($0.status) } }

  /// The count of agents that need you: now, then each time it changes,
  /// whether an event or a request's snapshot changed it.
  public func needsYouCounts() -> AsyncStream<Int> {
    countFollowers.add(first: needsYouCount) { [weak self] id in Task { await self?.forgetCountFollower(id) } }
  }

  private func forgetCountFollower(_ id: UUID) {
    countFollowers.forget(id)
  }

  /// Every change from now on, as it's logged: from an event as it happens,
  /// or from a snapshot that found a difference the stream didn't report,
  /// timed when Holler noticed. The stream runs until its follower stops
  /// listening, through `stop()` and `start()` again.
  public func changes() -> AsyncStream<Change> {
    changeFollowers.add { [weak self] id in Task { await self?.forgetChangeFollower(id) } }
  }

  private func forgetChangeFollower(_ id: UUID) {
    changeFollowers.forget(id)
  }

  /// Starts following Herdr's events, reconnecting whenever the stream drops.
  /// Without a source it does nothing, and only snapshots are watched.
  public func start() {
    guard loop == nil, let source else { return }
    loop = Task { await keepSubscribed(to: source) }
  }

  public func stop() {
    loop?.cancel()
    loop = nil
    isLive = false
  }

  /// Takes in the agents a request's snapshot found, and returns the picture
  /// it sees: how long each has been working or not, and the changes after
  /// `mark`, or none without one.
  public func observe(_ agents: [HerdrAgent], after mark: Mark?) -> Picture {
    catchUp(agents)
    noticed()
    let since = watched.mapValues(\.since)
    let changes = mark.map { mark in history.filter { $0.sequence > mark.sequence }.map(\.change) } ?? []
    return Picture(mark: Mark(sequence: sequence, date: now()), since: since, changes: changes, isLive: isLive)
  }

  /// The request that took `mark`'s picture went through: the next one asks
  /// about the changes after it.
  public func asked(_ mark: Mark) {
    lastAsked = mark
    unsaved = true
    save()
  }

  /// What the watcher holds for one agent, without taking anything in. For tests.
  func watching(_ paneId: String) -> (status: String, since: Since)? {
    watched[paneId].map { ($0.status, $0.since) }
  }

  // MARK: - Private

  /// Brings the picture in line with a snapshot's agents, leaving out any the
  /// filter hides. A difference the stream didn't report is timed now, as
  /// having happened by now.
  private func catchUp(_ agents: [HerdrAgent]) {
    let agents = agents.filter(herdr.filter.allows)
    let time = now()
    for agent in agents {
      let name = "\(agent.workspace) / \(agent.tab)"
      if let entry = watched[agent.paneId], Self.sameTerminal(entry.terminalId, agent.terminalId) {
        if entry.name != name || entry.terminalId != agent.terminalId {
          watched[agent.paneId]?.name = name
          watched[agent.paneId]?.terminalId = agent.terminalId
          unsaved = true
        }
        record(agent.paneId, agent.status, at: time, exact: false)
      } else {
        // Another agent's pane id before Herdr restarted: that one has closed.
        if let gone = watched[agent.paneId] { close(agent.paneId, gone, at: time) }
        // An agent that appears while events come in has only just started.
        let exact = seeded && isLive
        watched[agent.paneId] = Watched(
          name: name, status: agent.status, since: Since(date: time, exact: exact), terminalId: agent.terminalId)
        unsaved = true
        if seeded { log(Change(paneId: agent.paneId, name: name, from: nil, to: agent.status, at: time, exact: exact)) }
      }
    }
    let present = Set(agents.map(\.paneId))
    for (paneId, gone) in watched where !present.contains(paneId) { close(paneId, gone, at: time) }
    seeded = true
  }

  /// Whether a pane still holds the terminal it did. Without an id on either
  /// side there's no telling, so the pane is taken to be the same.
  private static func sameTerminal(_ known: String?, _ seen: String?) -> Bool {
    guard let known, let seen else { return true }
    return known == seen
  }

  private func close(_ paneId: String, _ gone: Watched, at time: Date) {
    log(Change(paneId: paneId, name: gone.name, from: gone.status, to: nil, at: time, exact: false))
    watched[paneId] = nil
  }

  /// A new status for an agent being watched. Moving between statuses that
  /// aren't working, like done to idle once you've looked, keeps its time:
  /// it has still been waiting since it stopped.
  private func record(_ paneId: String, _ status: String, at time: Date, exact: Bool) {
    guard let entry = watched[paneId], entry.status != status else { return }
    log(Change(paneId: paneId, name: entry.name, from: entry.status, to: status, at: time, exact: exact))
    watched[paneId]?.status = status
    if (entry.status == "working") != (status == "working") {
      watched[paneId]?.since = Since(date: time, exact: exact)
    }
  }

  private func log(_ change: Change) {
    sequence += 1
    history.append((sequence, change))
    if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    unsaved = true
    changeFollowers.yield(change)
  }

  /// After a look or an event: saves the picture, and tells whoever follows
  /// the count of agents that need you if it changed.
  private func noticed() {
    save()
    let count = needsYouCount
    guard count != lastCount else { return }
    lastCount = count
    countFollowers.yield(count)
  }

  /// Writes the picture to the file if it has changed since the last write:
  /// once per look or event, however many changes that brought. A picture
  /// that can't be written is still kept until Holler quits.
  private func save() {
    guard unsaved else { return }
    unsaved = false
    guard let file else { return }
    Saved(
      sequence: sequence, lastAsked: lastAsked,
      agents: watched.sorted { $0.key < $1.key }.map { paneId, entry in
        Saved.Agent(
          paneId: paneId, terminalId: entry.terminalId, name: entry.name, status: entry.status, since: entry.since.date,
          exact: entry.since.exact)
      },
      changes: history.map { sequence, change in
        Saved.Change(
          sequence: sequence, paneId: change.paneId, name: change.name, from: change.from, to: change.to, at: change.at,
          exact: change.exact)
      }
    ).write(to: file)
  }

  /// Subscribes, follows, and subscribes again, for as long as it runs.
  private func keepSubscribed(to source: any HerdrEventSource) async {
    var failures = 0
    while !Task.isCancelled {
      do {
        let panes = try await herdr.agents().map(\.paneId)
        if try await follow(source.subscribe(panes: panes), subscribedTo: Set(panes)) {
          failures = 0
          try await Task.sleep(for: settle)
          continue
        }
      } catch {}
      // Dropped, or never started: snapshots carry on alone until it's back.
      isLive = false
      let delay = retryDelays[min(failures, retryDelays.count - 1)]
      failures += 1
      try? await Task.sleep(for: delay)
    }
  }

  /// Follows one subscription. True when it ended because the agents may
  /// have changed, so the next one should cover a new set of panes; false
  /// when Herdr hung up.
  private func follow(_ events: AsyncThrowingStream<HerdrEvent, any Error>, subscribedTo panes: Set<String>)
    async throws -> Bool
  {
    for try await event in events {
      switch event {
      case .subscribed:
        // Anything that changed before the subscription began is caught up
        // from a snapshot taken after it.
        let agents = try await herdr.agents()
        catchUp(agents)
        noticed()
        isLive = true
        if Set(agents.map(\.paneId)) != panes { return true }
      case .statusChanged(let paneId, let status):
        record(paneId, status, at: now(), exact: true)
        noticed()
      case .agentsChanged:
        return true
      }
    }
    return false
  }
}
