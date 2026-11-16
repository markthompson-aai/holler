import Foundation

/// The agent list: one row per agent Holler can see, shown in the note the
/// moment you let go of the key, from the snapshot the request starts from,
/// until the answer replaces it. Laid out as a summary is, what needs you
/// first, with how long each agent has been as it is when the watcher knows.
enum AgentList {
  /// What the list keeps of one agent, from the snapshot or a change since.
  struct Entry: Sendable, Equatable {
    /// Herdr's pane id, which a change names the agent by.
    var paneId: String
    /// "workspace / tab", as a summary names an agent.
    var name: String
    /// Herdr's status: working, idle, blocked, done or unknown.
    var status: String
    /// When it last started or stopped working, when the watcher knows.
    var since: HerdrWatcher.Since?
  }

  /// The entries for a snapshot's agents, timed by the watcher's picture.
  static func entries(_ agents: [HerdrAgent], since: [String: HerdrWatcher.Since]) -> [Entry] {
    agents.map { Entry(paneId: $0.paneId, name: "\($0.workspace) / \($0.tab)", status: $0.status, since: since[$0.paneId]) }
  }

  /// The entries with a change the watcher reported: an agent that closed
  /// drops off, one that appeared joins, and one that started or stopped
  /// working starts its time over from the change. As in the watcher, a
  /// change between statuses that aren't working, like done to idle, keeps
  /// its time: it has still been waiting since it stopped.
  static func applying(_ change: HerdrWatcher.Change, to entries: [Entry]) -> [Entry] {
    guard let status = change.to else { return entries.filter { $0.paneId != change.paneId } }
    let since = HerdrWatcher.Since(date: change.at, exact: change.exact)
    guard let index = entries.firstIndex(where: { $0.paneId == change.paneId }) else {
      return entries + [Entry(paneId: change.paneId, name: change.name, status: status, since: since)]
    }
    var changed = entries
    changed[index].status = status
    if (change.from == "working") != (status == "working") { changed[index].since = since }
    return changed
  }

  /// The rows as the note shows them, what needs you first, timed at `now`.
  static func rows(_ entries: [Entry], now: Date) -> [AgentRow] {
    entries.map {
      AgentRow(name: $0.name, state: AgentRow.State(herdrStatus: $0.status), update: wait($0.status, since: $0.since, now: now))
    }
    .sorted { $0.state < $1.state }
  }

  /// "Waiting 12 min.", "Working for 3 min.", "Stopped 12 min ago.", with
  /// "at least" when Holler only knows it was so by then, as the model is
  /// told; nothing when the watcher has only just seen the agent, or there
  /// is no watcher.
  static func wait(_ status: String, since: HerdrWatcher.Since?, now: Date) -> String {
    guard let span = AssistantPrompt.span(since: since, now: now) else { return "" }
    return switch status {
    case "working": "Working for \(span)."
    case "blocked": "Waiting \(span)."
    case "idle", "done": "Stopped \(span) ago."
    default: ""
    }
  }
}
