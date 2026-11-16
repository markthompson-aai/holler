import Foundation

/// One line of the turn log, read back: the `key=value` pairs the controller's
/// `timingLine` or `failureLine` wrote, with whatever `log show` put in front
/// of them. Keys are kept as written, so a line from an older or newer build
/// still reads; ask for a field and get nil when that build didn't log it.
public struct TurnRecord: Sendable, Equatable {
  public struct Tool: Sendable, Equatable {
    public var name: String
    public var failed: Bool

    public init(name: String, failed: Bool) {
      self.name = name
      self.failed = failed
    }
  }

  /// The minute the line was logged, as `log show` printed it, when it did.
  public var loggedAt: String?
  /// A request that ended in an error instead of an answer.
  public var failed: Bool
  public var fields: [String: String]
  /// The tools called, in order; nil when the line predates the `tools` field.
  public var tools: [Tool]?
  /// A failed line's reason, which may contain spaces.
  public var error: String?

  /// A duration field, in milliseconds; nil when it reads `n/a` or is missing.
  public func milliseconds(_ key: String) -> Int? { int(key) }

  public func int(_ key: String) -> Int? { fields[key].flatMap(Int.init) }

  /// Reads a logged line, or nil for any other line.
  public static func parse(_ line: String) -> TurnRecord? {
    let markers = ["turn totalMs=", "turn failed totalMs="]
    guard let start = markers.compactMap({ line.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
    let prefix = line[..<start.lowerBound]
    let body = line[start.lowerBound...].dropFirst("turn ".count)
    let failed = body.hasPrefix("failed ")
    var record = TurnRecord(loggedAt: prefix.firstMatch(of: /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}/).map { String($0.output) }, failed: failed, fields: [:])

    var rest = failed ? body.dropFirst("failed ".count) : body
    while let token = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first {
      if token.hasPrefix("error=") {
        // The reason runs to the end of the line, spaces and all.
        record.error = String(rest.dropFirst("error=".count))
        break
      }
      if let equals = token.firstIndex(of: "=") {
        record.fields[String(token[..<equals])] = String(token[token.index(after: equals)...])
      }
      rest = rest[token.endIndex...].drop(while: { $0 == " " })
    }
    if let tools = record.fields["tools"] {
      record.tools = tools == "none" ? [] : tools.split(separator: ",").map { Tool(name: String($0.hasSuffix("!") ? $0.dropLast() : $0), failed: $0.hasSuffix("!")) }
    }
    return record
  }
}

public enum TurnLog {
  /// Every turn line in `text`, oldest first, skipping anything else `log show` printed.
  public static func records(in text: String) -> [TurnRecord] {
    text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { TurnRecord.parse(String($0)) }
  }

  /// A window such as `7d`, `24h` or `30m`, the form `log show --last` takes.
  public static func window(_ text: String) -> Duration? {
    guard let match = text.wholeMatch(of: /(\d+)([mhd])/), let count = Int(match.output.1) else { return nil }
    switch match.output.2 {
    case "m": return .seconds(count * 60)
    case "h": return .seconds(count * 3_600)
    default: return .seconds(count * 86_400)
    }
  }
}

/// Where the time has been going, over many turns: each stage's p50, p95 and
/// max across the answered turns, token totals, how many rounds turns took,
/// and how many turns called each tool. Failed turns are counted, not timed,
/// since their times only say how long the failure took.
public struct TurnStats: Sendable {
  public struct Stage: Sendable, Equatable {
    public var name: String
    /// How many turns logged this stage; a typed request has no transcript.
    public var count: Int
    public var p50: Duration
    public var p95: Duration
    public var max: Duration
  }

  public struct Rounds: Sendable, Equatable {
    public var rounds: Int
    public var turns: Int

    public init(rounds: Int, turns: Int) {
      self.rounds = rounds
      self.turns = turns
    }
  }

  public struct ToolUse: Sendable, Equatable {
    public var name: String
    /// Turns that called it at least once.
    public var turns: Int
    /// Turns in which at least one of its calls failed.
    public var failed: Int

    public init(name: String, turns: Int, failed: Int) {
      self.name = name
      self.turns = turns
      self.failed = failed
    }
  }

  /// The stages in the order a turn goes through them, by their log key.
  static let stageKeys: [(name: String, key: String)] = [
    ("total", "totalMs"), ("transcript", "transcriptMs"), ("herdr", "herdrMs"), ("read", "readMs"),
    ("model", "modelMs"), ("tools", "toolsMs"), ("speech", "speechMs"),
  ]

  public var answered: Int
  public var failed: Int
  /// Only the stages at least one turn logged.
  public var stages: [Stage]
  public var tokensIn: Int
  public var tokensCached: Int
  public var tokensOut: Int
  /// Fewest rounds first.
  public var rounds: [Rounds]
  /// Most used first, then by name.
  public var tools: [ToolUse]
  /// Answered turns that called no tool at all.
  public var withoutTools: Int
  /// When the first and last of these turns were logged, if the lines said.
  public var first: String?
  public var last: String?

  public init(_ records: [TurnRecord]) {
    let answered = records.filter { !$0.failed }
    self.answered = answered.count
    failed = records.count - answered.count
    stages = Self.stageKeys.compactMap { stage in
      let values = answered.compactMap { $0.milliseconds(stage.key) }.sorted()
      guard !values.isEmpty else { return nil }
      return Stage(
        name: stage.name, count: values.count, p50: .milliseconds(Self.percentile(values, 0.5)),
        p95: .milliseconds(Self.percentile(values, 0.95)), max: .milliseconds(values[values.count - 1]))
    }
    tokensIn = answered.compactMap { $0.int("tokensIn") }.reduce(0, +)
    tokensCached = answered.compactMap { $0.int("tokensCached") }.reduce(0, +)
    tokensOut = answered.compactMap { $0.int("tokensOut") }.reduce(0, +)
    var byRounds: [Int: Int] = [:]
    for count in answered.compactMap({ $0.int("rounds") }) { byRounds[count, default: 0] += 1 }
    rounds = byRounds.keys.sorted().map { Rounds(rounds: $0, turns: byRounds[$0]!) }

    var uses: [String: ToolUse] = [:]
    var withoutTools = 0
    for turn in answered {
      guard let tools = turn.tools else { continue }
      if tools.isEmpty { withoutTools += 1 }
      for name in Set(tools.map(\.name)) {
        uses[name, default: ToolUse(name: name, turns: 0, failed: 0)].turns += 1
        if tools.contains(where: { $0.name == name && $0.failed }) { uses[name]!.failed += 1 }
      }
    }
    tools = uses.values.sorted { ($0.turns, $1.name) > ($1.turns, $0.name) }
    self.withoutTools = withoutTools
    let times = records.compactMap(\.loggedAt)
    first = times.first
    last = times.last
  }

  /// Nearest-rank percentile of sorted values: the value at least `p` of them don't exceed.
  static func percentile(_ sorted: [Int], _ p: Double) -> Int {
    sorted[Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
  }

  /// The compact table `holler stats` prints. `window` is what the turns
  /// were taken from, such as `7d`; without one the heading gives their span.
  public func table(window: String?) -> String {
    let within = window.map { " in the last \($0)" } ?? ""
    guard answered + failed > 0 else { return "No turns\(within)." }
    var heading = "\(answered + failed) turn\(answered + failed == 1 ? "" : "s")"
    if window != nil {
      heading += within
    } else if let first, let last {
      heading += first == last ? " at \(first)" : " from \(first) to \(last)"
    }
    if failed > 0 { heading += ", \(failed) failed" }

    var lines = [heading]
    if !stages.isEmpty {
      lines.append(Self.row("", ["p50", "p95", "max"]))
      for stage in stages {
        lines.append(Self.row(stage.name, [stage.p50, stage.p95, stage.max].map(Self.seconds)))
      }
    }
    lines.append(Self.row("tokens", "in \(tokensIn) · cached \(tokensCached) · out \(tokensOut)"))
    if !rounds.isEmpty {
      lines.append(Self.row("rounds", rounds.map { "\($0.rounds) ×\($0.turns)" }.joined(separator: " · ")))
    }
    var uses = tools.map { "\($0.name) ×\($0.turns)" + ($0.failed > 0 ? " (\($0.failed) failed)" : "") }
    if withoutTools > 0 { uses.append("none ×\(withoutTools)") }
    if !uses.isEmpty {
      lines.append(Self.row("tools used", uses.joined(separator: " · ")))
    } else if answered > 0 {
      lines.append(Self.row("tools used", "not logged by this build"))
    }
    return lines.joined(separator: "\n")
  }

  private static let labelWidth = 12
  private static let columnWidth = 8

  private static func row(_ label: String, _ columns: [String]) -> String {
    row(label, columns.map { String(repeating: " ", count: Swift.max(0, columnWidth - $0.count)) + $0 }.joined())
  }

  private static func row(_ label: String, _ text: String) -> String {
    label + String(repeating: " ", count: Swift.max(1, labelWidth - label.count)) + text
  }

  /// Hundredths of a second, rounded half up from the logged milliseconds.
  private static func seconds(_ duration: Duration) -> String {
    let centiseconds = (Int(duration / .milliseconds(1)) + 5) / 10
    return "\(centiseconds / 100).\(String(format: "%02d", centiseconds % 100))s"
  }
}
