import Foundation

/// Which agents Holler may see. Anything filtered out is invisible to the
/// model and can't be read or sent a message.
public struct AgentFilter: Sendable, Equatable {
  /// Folders whose agents are hidden, e.g. ones that may show customer data,
  /// as absolute paths: `~` and `$HOME` expanded, `..` and a trailing slash
  /// taken out. An entry that isn't an absolute path once expanded hides
  /// nothing and is left out; `problems(inExcludedPaths:)` says so.
  public let excludedPathPrefixes: [String]
  /// Workspace labels to limit to, case-insensitively; empty means all. For a
  /// demo: only the demo workspace, whatever else is open.
  public var workspaces: [String]
  /// Every way each excluded folder may be written, for comparing.
  private let excluded: [String]

  /// `excludedPathPrefixes` as the user wrote them in `HOLLER_EXCLUDE_PATHS`:
  /// spaces round an entry, `~`, `$HOME` and a trailing slash are all fine.
  public init(excludedPathPrefixes: [String] = [], workspaces: [String] = []) {
    self.excludedPathPrefixes = excludedPathPrefixes.compactMap(Self.absolute)
    // Sorted, so two filters from the same settings compare equal.
    excluded = Set(self.excludedPathPrefixes.flatMap(Self.forms)).sorted()
    self.workspaces = workspaces.filter { !$0.isEmpty }
  }

  public func allows(_ agent: HerdrAgent) -> Bool {
    allowsWorkspace(agent.workspace) && allowsFolder(agent.cwd)
  }

  public func allowsWorkspace(_ label: String) -> Bool {
    workspaces.isEmpty || workspaces.contains { $0.caseInsensitiveCompare(label) == .orderedSame }
  }

  /// Whether `path` is outside every excluded folder. The comparison ignores
  /// case, as the Mac's file system does, and follows symlinks on both
  /// sides, so a folder is hidden however it or the exclusion is spelled:
  /// through a symlink, or as /tmp when Herdr reports /private/tmp. The path
  /// needn't exist yet: the nearest folder above it that does is resolved,
  /// so a new worktree is checked before it's made.
  public func allowsFolder(_ path: String) -> Bool {
    // Herdr gave no folder, or a relative one: there's nothing to compare.
    guard !excluded.isEmpty, path.hasPrefix("/") else { return true }
    return !Self.forms(path).contains { form in excluded.contains { Self.isInside(form, $0) } }
  }

  /// Whether an excluded folder sits inside `path`, which a copy of `path`,
  /// like a git worktree, would bring out into the open.
  public func excludesFolder(inside path: String) -> Bool {
    guard path.hasPrefix("/") else { return false }
    let outer = Self.forms(path)
    return excluded.contains { folder in outer.contains { folder != $0 && Self.isInside(folder, $0) } }
  }

  /// What's wrong with the entries of `HOLLER_EXCLUDE_PATHS`, one line each,
  /// worded for the log: an entry that isn't an absolute path hides nothing,
  /// and one that doesn't exist is probably misspelled.
  public static func problems(inExcludedPaths entries: [String]) -> [String] {
    entries.compactMap { entry in
      let written = entry.trimmingCharacters(in: .whitespaces)
      guard !written.isEmpty else { return nil }
      guard let path = absolute(entry) else {
        return "HOLLER_EXCLUDE_PATHS: \"\(written)\" isn't an absolute path, so it hides nothing; start it with / or ~"
      }
      guard FileManager.default.fileExists(atPath: path) else {
        return "HOLLER_EXCLUDE_PATHS: \(path) doesn't exist, so check its spelling; it hides nothing until it does"
      }
      return nil
    }
  }

  // MARK: - Paths

  /// An entry as an absolute path, or nil if it isn't one once `~` and
  /// `$HOME` are expanded.
  private static func absolute(_ entry: String) -> String? {
    var path = entry.trimmingCharacters(in: .whitespaces)
    for home in ["${HOME}", "$HOME"] where path == home || path.hasPrefix(home + "/") {
      path = NSHomeDirectory() + path.dropFirst(home.count)
    }
    path = (path as NSString).expandingTildeInPath
    guard path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  /// `path` as it may be written: standardised, and with its symlinks
  /// resolved, both lowercased with accents composed. A path that doesn't
  /// exist is resolved as far up as it does.
  private static func forms(_ path: String) -> [String] {
    let standard = URL(fileURLWithPath: path).standardizedFileURL
    var existing = standard
    var rest: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
      rest.insert(existing.lastPathComponent, at: 0)
      existing.deleteLastPathComponent()
    }
    let resolved = rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    return Array(Set([standard.path, resolved.path].map { $0.precomposedStringWithCanonicalMapping.lowercased() }))
  }

  /// Whether `path` is `folder` or somewhere under it.
  private static func isInside(_ path: String, _ folder: String) -> Bool {
    path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
  }
}
