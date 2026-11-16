import Foundation

/// Runtime settings: the process environment, falling back to a `.env` file.
public struct Settings: Sendable, Equatable {
  public static let defaultModel = "claude-sonnet-5-5"
  /// Half the wait of the model's own default on summaries and read-alouds,
  /// with the same answers.
  public static let defaultEffort = "medium"
  /// The effort levels LLM Gateway takes for Claude; `HOLLER_EFFORT` also
  /// takes `default`, for the model's own.
  public static let efforts = ["low", "medium", "high", "xhigh", "max"]

  /// The key you hold to ask: one of the keys Blurt's hotkey engine can
  /// trigger on, named plainly in `HOLLER_HOTKEY`.
  public enum Hotkey: String, CaseIterable, Sendable {
    case rightOption = "right-option"
    case rightCommand = "right-command"
    case function = "fn"

    public static let `default` = Hotkey.rightOption

    /// In a sentence: "Hold right ⌥ to ask".
    public var label: String {
      switch self {
      case .rightOption: "right ⌥"
      case .rightCommand: "right ⌘"
      case .function: "fn"
      }
    }

    /// On the note's keycap.
    public var symbol: String {
      switch self {
      case .rightOption: "⌥"
      case .rightCommand: "⌘"
      case .function: "fn"
      }
    }

    /// As VoiceOver reads it: "Hold right Option to follow up".
    public var spokenName: String {
      switch self {
      case .rightOption: "right Option"
      case .rightCommand: "right Command"
      case .function: "fn"
      }
    }

    /// The names `HOLLER_HOTKEY` takes, for the log line.
    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }
  }

  public var apiKey: String?
  public var model: String
  /// Claude's effort level for answers; nil leaves the model's default.
  public var effort: String?
  /// The voice for answers read aloud, by name or identifier; nil picks one.
  public var voice: String?
  public var herdrPath: URL?
  public var filter: AgentFilter
  public var hotkey: Hotkey
  /// Why `hotkey` is the default when `HOLLER_HOTKEY` named something
  /// else, worded for the log; nil when the setting was taken as given.
  public var hotkeyProblem: String?
  /// What's wrong with `HOLLER_EXCLUDE_PATHS`, one line per entry that hides
  /// nothing, worded for the log; empty when every entry is a folder that exists.
  public var excludeProblems: [String]

  /// Why `effort` is the default when `HOLLER_EFFORT` named something else,
  /// worded for the log; nil when the setting was taken as given.
  public var effortProblem: String?

  /// Everything in the settings that isn't doing what was meant, for the log.
  public var problems: [String] { excludeProblems + [effortProblem, hotkeyProblem].compactMap { $0 } }

  public init(environment: [String: String]) {
    func value(_ key: String) -> String? {
      environment[key].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    apiKey = value("ASSEMBLYAI_API_KEY")
    model = value("HOLLER_MODEL") ?? Self.defaultModel
    // "default" sends none, leaving the model's own. Anything else the
    // gateway would refuse on every request, so it falls back and says so.
    switch value("HOLLER_EFFORT")?.lowercased() {
    case nil: effort = Self.defaultEffort
    case "default": effort = nil
    case let name? where Self.efforts.contains(name): effort = name
    case let name?:
      effort = Self.defaultEffort
      effortProblem =
        "HOLLER_EFFORT=\(name) isn't an effort level Holler knows (\(Self.efforts.joined(separator: ", ")), default); "
        + "using \(Self.defaultEffort)"
    }
    voice = value("HOLLER_VOICE")
    herdrPath = HerdrClient.locate(environment: environment)
    let excluded = (value("HOLLER_EXCLUDE_PATHS") ?? "").split(separator: ":").map(String.init)
    excludeProblems = AgentFilter.problems(inExcludedPaths: excluded)
    filter = AgentFilter(
      excludedPathPrefixes: excluded,
      workspaces: (value("HOLLER_WORKSPACES") ?? "").split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
      })
    if let name = value("HOLLER_HOTKEY"), Hotkey(rawValue: name.lowercased()) == nil {
      hotkey = .default
      hotkeyProblem =
        "HOLLER_HOTKEY=\(name) isn't a key Holler knows (\(Hotkey.names)); using \(Hotkey.default.label)"
    } else {
      hotkey = value("HOLLER_HOTKEY").flatMap { Hotkey(rawValue: $0.lowercased()) } ?? .default
    }
  }

  /// Process environment wins over the file, so a one-off
  /// `HOLLER_MODEL=… holler …` overrides `.env`.
  public static func load(dotEnv: URL?) -> Settings {
    var environment = dotEnv.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(DotEnv.parse) ?? [:]
    environment.merge(ProcessInfo.processInfo.environment) { _, process in process }
    return Settings(environment: environment)
  }

  /// The settings that differ from `old`, by name, for a reload's log line.
  public func changes(from old: Settings) -> [String] {
    var changed: [String] = []
    if apiKey != old.apiKey { changed.append("API key") }
    if model != old.model { changed.append("model") }
    if effort != old.effort { changed.append("effort") }
    if voice != old.voice { changed.append("voice") }
    if herdrPath != old.herdrPath { changed.append("herdr path") }
    if filter != old.filter { changed.append("filter") }
    if hotkey != old.hotkey { changed.append("hotkey") }
    return changed
  }
}

public enum DotEnv {
  /// `KEY=value` lines; `#` comments, on a line of their own or after a
  /// value, blank lines, `export ` prefixes and surrounding quotes are
  /// handled. No variable expansion.
  public static func parse(_ contents: String) -> [String: String] {
    var result: [String: String] = [:]
    for rawLine in contents.split(whereSeparator: \.isNewline) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("export ") { line.removeFirst("export ".count) }
      guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces)
      if !key.isEmpty { result[key] = value(line[line.index(after: separator)...]) }
    }
    return result
  }

  /// What follows the `=`: the text inside its quotes, or, unquoted, the
  /// text up to a comment. A `#` only starts a comment after a space, so
  /// `COLOUR=#fff` keeps its value, and one inside quotes is part of it.
  private static func value(_ written: Substring) -> String {
    let trimmed = written.trimmingCharacters(in: .whitespaces)
    if let quote = trimmed.first, quote == "\"" || quote == "'" {
      let inside = trimmed.dropFirst()
      // The closing quote is the last one with nothing but a comment after it.
      if let close = inside.lastIndex(of: quote) {
        let after = inside[inside.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if after.isEmpty || after.hasPrefix("#") { return String(inside[..<close]) }
      }
      if let close = inside.firstIndex(of: quote) {
        let after = inside[inside.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if after.hasPrefix("#") { return String(inside[..<close]) }
      }
    }
    var end = written.endIndex
    var previous: Character = "="
    for index in written.indices {
      if written[index] == "#", previous.isWhitespace {
        end = index
        break
      }
      previous = written[index]
    }
    return written[..<end].trimmingCharacters(in: .whitespaces)
  }

  /// The nearest `.env` at or above `directory`.
  public static func find(from directory: URL) -> URL? {
    var current = directory.standardizedFileURL
    while true {
      let candidate = current.appendingPathComponent(".env")
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { return nil }
      current = parent
    }
  }
}
