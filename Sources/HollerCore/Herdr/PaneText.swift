import Foundation

/// Shrinks raw terminal text before it goes to the model: drops TUI chrome
/// (box-drawing rules, blank runs) and keeps only the most recent characters.
/// Whatever is missing is said in a bracketed first line, so the model can
/// report it rather than guess at it.
public enum PaneText {
  /// The cut every read gets unless it asks for its own, sized for a
  /// screen or a confirm card. A read of a whole scrollback asks for more.
  public static let maxCharacters = 12_000

  /// The first line of a read that could only see the agent's screen, because
  /// Herdr refuses the scrollback of a working agent.
  public static let screenOnly = "[visible screen only: the agent is working, so its earlier output can't be read]"

  /// The first line of a read that fell back to the screen because reading
  /// the scrollback timed out.
  public static let readTimedOut = "[visible screen only: reading the agent's earlier output timed out]"

  /// The first line of a cut read: about how much came before what's kept.
  public static func leftOut(_ characters: Int) -> String {
    "[earlier output left out: about \(roughly(characters)) characters]"
  }

  public static func clean(_ raw: String, maxCharacters: Int = maxCharacters) -> String {
    var lines: [Substring] = []
    var previousBlank = false
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingTrailingWhitespace()
      if trimmed.allSatisfy(isChrome) {
        if !previousBlank, !lines.isEmpty { lines.append("") }
        previousBlank = true
        continue
      }
      lines.append(trimmed)
      previousBlank = false
    }
    let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let count = text.count
    guard count > maxCharacters else { return text }
    return leftOut(count - maxCharacters) + "\n" + text.suffix(maxCharacters)
  }

  /// `count` to two significant figures, with thousands separators: 61,347
  /// reads "61,000", 1,234 "1,200", 6 "6".
  private static func roughly(_ count: Int) -> String {
    var unit = 1
    while count / unit >= 100 { unit *= 10 }
    return ((count / unit) * unit).formatted(.number.locale(Locale(identifier: "en_US")))
  }

  /// Whether a line is one of the markers above, Holler's own words rather
  /// than the agent's.
  static func isMarker(_ line: String) -> Bool {
    line == screenOnly || line == readTimedOut || line.hasPrefix("[earlier output left out: ")
  }

  /// The agent's last line of output, for a confirm card: the last line above
  /// its input prompt (Claude's ❯, Codex's ›), skipping spinner and timer lines
  /// such as "✻ Baked for 5s" and Holler's own markers, without a leading
  /// response bullet.
  public static func lastLine(_ raw: String, maxCharacters: Int = 140) -> String? {
    var lines = clean(raw).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !isMarker($0) }
    if let prompt = lines.lastIndex(where: { $0.hasPrefix("❯") || $0.hasPrefix("›") }) {
      lines = Array(lines[..<prompt])
    }
    let spinners: Set<Character> = ["✻", "✳", "✶", "✢", "✽", "·", "*"]
    guard var line = lines.last(where: { !spinners.contains($0.first!) }) else { return nil }
    if let first = line.first, ["⏺", "•"].contains(first) {
      line = line.dropFirst().trimmingCharacters(in: .whitespaces)
    }
    return line.count > maxCharacters ? line.prefix(maxCharacters - 1) + "…" : line
  }

  /// The lines of a cleaned screen that weren't on an earlier one, in order:
  /// what an agent has written since then. A line that was already there,
  /// even if it has scrolled up, isn't new, so the input box and footer drop
  /// out and a changing spinner line stays. Keeps the last `maxCharacters`.
  public static func newLines(since earlier: String, in screen: String, maxCharacters: Int = 1_000) -> [String] {
    var before: [Substring: Int] = [:]
    for line in earlier.split(separator: "\n") { before[line.trimmingTrailingWhitespace(), default: 0] += 1 }
    var lines: [String] = []
    for line in screen.split(separator: "\n") {
      let trimmed = line.trimmingTrailingWhitespace()
      if let count = before[trimmed], count > 0 {
        before[trimmed] = count - 1
      } else if !trimmed.allSatisfy(\.isWhitespace) {
        lines.append(String(trimmed))
      }
    }
    var kept: [String] = []
    var total = 0
    for line in lines.reversed() {
      total += line.count + 1
      if total > maxCharacters { break }
      kept.insert(line, at: 0)
    }
    if kept.count < lines.count { kept.insert("…", at: 0) }
    return kept
  }

  /// Whitespace and box-drawing/block characters, which carry no content.
  private static func isChrome(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { scalar in
      scalar.properties.isWhitespace || (0x2500...0x259F).contains(scalar.value)
    }
  }
}

extension Substring {
  fileprivate func trimmingTrailingWhitespace() -> Substring {
    var end = endIndex
    while end > startIndex, self[index(before: end)].isWhitespace {
      end = index(before: end)
    }
    return self[startIndex..<end]
  }
}
