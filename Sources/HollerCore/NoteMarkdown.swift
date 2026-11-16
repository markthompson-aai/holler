import Foundation

/// The block structure of an answer: just what the note renders (paragraphs,
/// bullets, headings). Inline styling (`**bold**`, `code`) is left in the text
/// for the view's inline Markdown rendering.
public enum NoteBlock: Equatable, Sendable {
  case paragraph(String)
  case bullet(String)
  /// A bullet indented under the one before it.
  case subBullet(String)
  case heading(String)

  public static func parse(_ markdown: String) -> [NoteBlock] {
    var blocks: [NoteBlock] = []
    var paragraph: [String] = []

    func flush() {
      if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
      paragraph.removeAll()
    }

    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty {
        flush()
      } else if let item = bulletText(line) {
        flush()
        let indented = rawLine.prefix { $0 == " " || $0 == "\t" }.count >= 2
        blocks.append(indented && !blocks.isEmpty ? .subBullet(item) : .bullet(item))
      } else if line.hasPrefix("#") {
        flush()
        blocks.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
      } else if paragraph.isEmpty, rawLine.first?.isWhitespace == true, let last = blocks.last,
        let continued = last.appending(line)
      {
        // An indented continuation of the previous bullet.
        blocks[blocks.count - 1] = continued
      } else {
        paragraph.append(line)
      }
    }
    flush()
    return blocks
  }

  private func appending(_ line: String) -> NoteBlock? {
    switch self {
    case .bullet(let text): .bullet(text + " " + line)
    case .subBullet(let text): .subBullet(text + " " + line)
    case .paragraph, .heading: nil
    }
  }

  private static func bulletText(_ line: String) -> String? {
    for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
      return String(line.dropFirst(marker.count))
    }
    // "1. item" numbered lists render as bullets too.
    if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
      line[line.index(after: dot)...].hasPrefix(" ")
    {
      return String(line[line.index(dot, offsetBy: 2)...])
    }
    return nil
  }
}

/// One agent's line in a summary, from a "**name**: state. update" bullet.
public struct AgentRow: Equatable, Sendable {
  /// In the order the note lists them: what needs you first.
  public enum State: Int, Comparable, Sendable {
    case needsYou, working, idle

    public static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The state for one of Herdr's statuses: blocked needs you, working
    /// works, and anything else (idle, done, unknown) is idle.
    public init(herdrStatus status: String) {
      self =
        switch status {
        case "blocked": .needsYou
        case "working": .working
        default: .idle
        }
    }
  }

  public let name: String
  public let state: State
  public let update: String

  public init(name: String, state: State, update: String) {
    self.name = name
    self.state = state
    self.update = update
  }

  /// "demo / api" → "demo". Nil when the name has no workspace.
  public var workspace: String? {
    name.range(of: " / ").map { String(name[..<$0.lowerBound]) }
  }

  /// "demo / api" → "api"; the whole name when it has no workspace.
  public var tab: String {
    name.range(of: " / ").map { String(name[$0.upperBound...]) } ?? name
  }

  /// "demo / api (w1:p2)" → "w1:p2": a pane id the model added to tell two
  /// agents in one tab apart. Nil when the name has none.
  public var paneId: String? {
    name.firstMatch(of: /w[0-9A-Za-z]+:p[0-9A-Za-z]+/).map { String($0.output) }
  }
}

/// An answer as the note lays it out: a summary of agents as rows under a
/// headline, or, for anything else (including a bullet whose status isn't
/// recognised), plain blocks.
public enum NoteAnswer: Equatable, Sendable {
  case summary(headline: String, subline: String?, agents: [AgentRow])
  case blocks([NoteBlock])

  public static func parse(_ markdown: String) -> NoteAnswer {
    let blocks = NoteBlock.parse(markdown)
    guard case .paragraph(let first)? = blocks.first, blocks.count > 1 else { return .blocks(blocks) }
    var agents: [AgentRow] = []
    for block in blocks.dropFirst() {
      guard case .bullet(let text) = block, let row = AgentRow(bullet: text) else { return .blocks(blocks) }
      agents.append(row)
    }
    // The model's headline can miscount or hedge, so the note counts the rows itself.
    return .summary(headline: count(agents), subline: subline(first), agents: agents.sorted { $0.state < $1.state })
  }

  /// The agent list laid out as a summary is: the counts as its headline,
  /// then the rows, what needs you first.
  public static func list(_ agents: [AgentRow]) -> NoteAnswer {
    .summary(headline: count(agents), subline: nil, agents: agents.sorted { $0.state < $1.state })
  }

  /// "1 needs you, 2 working, 3 idle", leaving out any count of zero.
  static func count(_ agents: [AgentRow]) -> String {
    let needYou = agents.count { $0.state == .needsYou }
    let working = agents.count { $0.state == .working }
    let idle = agents.count { $0.state == .idle }
    return [
      needYou > 0 ? "\(needYou) \(needYou == 1 ? "needs" : "need") you" : nil,
      working > 0 ? "\(working) working" : nil,
      idle > 0 ? "\(idle) idle" : nil,
    ].compactMap { $0 }.joined(separator: ", ")
  }

  /// "**2 working, 3 idle.** One needs you." → "One needs you."; the sentence after the bold headline.
  private static func subline(_ paragraph: String) -> String? {
    guard let match = paragraph.firstMatch(of: /^\*\*(.+?)\*\*\s*(.*)$/) else { return nil }
    let rest = String(match.2).trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? nil : rest
  }
}

extension AgentRow {
  init?(bullet: String) {
    guard let match = bullet.firstMatch(of: /^\*\*(.+?)\*\*:\s*(.*)$/) else { return nil }
    let rest = String(match.2)
    let (status, update) =
      if let dot = rest.firstIndex(of: ".") {
        (String(rest[..<dot]), String(rest[rest.index(after: dot)...]))
      } else {
        (rest, "")
      }
    let state: State
    switch status.lowercased().trimmingCharacters(in: .whitespaces) {
    case "needs you", "blocked", "waiting", "waiting on you": state = .needsYou
    case "working": state = .working
    case "idle", "done": state = .idle
    default: return nil
    }
    self.init(name: String(match.1), state: state, update: update.trimmingCharacters(in: .whitespaces))
  }
}
