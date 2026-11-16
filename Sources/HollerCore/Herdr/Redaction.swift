import Foundation

/// Replaces secret-looking strings in pane text with a short marker, so a key
/// or token shown in a terminal doesn't leave the Mac. Every pane read passes
/// through `redact` before the model, the note or the CLI sees the text, and
/// so do the terminal titles and tab names in the agent list.
///
/// It is a net, not a guarantee: it knows the shapes listed below, and a
/// secret in another shape gets through. `HOLLER_EXCLUDE_PATHS` is the way to
/// keep a folder's agents away from the model altogether.
///
/// Each replacement stays on its own line and a private key block keeps its
/// line count, so Herdr line references still line up.
///
/// Ordinary code and output pass through: git SHAs (7 to 40 hex), UUIDs with
/// dashes, file paths and words. The accepted collateral is a 32-hex string on
/// its own, such as a UUID without dashes or an MD5, because an AssemblyAI key
/// looks exactly like one, and the odd word after "secret:" or "password:".
public enum Redaction {
  public static func redact(_ text: String) -> String {
    var redacted = text
    redacted = redacted.replacing(privateKeyBlock) { match in
      "[redacted private key]" + String(repeating: "\n", count: match.output.count(where: { $0 == "\n" }))
    }
    // The generic pair goes first: a value it hides is gone before the
    // specific patterns run, so nothing is wrapped twice.
    redacted = redacted.replacing(secretAssignment) { match in
      let value = match.output.doubleQuoted ?? match.output.singleQuoted ?? match.output.bare ?? ""
      guard isSecret(value, named: match.output.lead) else { return String(match.output.full) }
      // Everything after the lead is the value and its quotes, if any.
      let tail = match.output.full.dropFirst(match.output.lead.count)
      return String(match.output.lead) + tail.replacing(value, with: "[redacted value]")
    }
    redacted = redacted.replacing(secretFlag) { match in "\(match.output.1)[redacted value]" }
    redacted = redacted.replacing(urlPassword) { match in "\(match.output.1)[redacted password]@" }
    redacted = redacted.replacing(userPassword) { match in "\(match.output.1)[redacted password]" }
    redacted = redacted.replacing(mysqlPassword) { match in "\(match.output.1)[redacted password]" }
    redacted = redacted.replacing(bearer) { match in "\(match.output.1)[redacted token]" }
    redacted = redacted.replacing(basic) { match in "\(match.output.1)[redacted token]" }
    redacted = redacted.replacing(jwt, with: "[redacted token]")
    redacted = redacted.replacing(prefixedToken, with: "[redacted token]")
    redacted = redacted.replacing(prefixedKey, with: "[redacted key]")
    redacted = redacted.replacing(assemblyAIKey, with: "[redacted key]")
    return continuing(redacted, from: text)
  }

  // MARK: - Tokens that wrap

  /// What a redaction can end a row with, when its secret ran to the row's end.
  private static let markers = ["[redacted value]", "[redacted token]", "[redacted key]", "[redacted password]"]

  /// The characters a key or token is made of.
  private static func isTokenCharacter(_ character: Character) -> Bool {
    character.isASCII && (character.isLetter || character.isNumber || "_-+/=.~%".contains(character))
  }

  /// A visible screen comes as one line per terminal row, so a token longer
  /// than what's left of its row carries on at the start of the next, where
  /// no pattern knows it. When a redaction ends a row at the screen's right
  /// edge, the run of token characters that opens the next row goes too, and
  /// so on down for as long as a row is nothing but token.
  ///
  /// The right edge is the longest row's length, and only counts when
  /// another row is as long: a screen has full-width rows, such as an
  /// agent's input box, where a list of settings merely has a longest line.
  /// A token whose first row no pattern matches on its own isn't caught.
  private static func continuing(_ redacted: String, from original: String) -> String {
    let rows = original.split(separator: "\n", omittingEmptySubsequences: false)
    var lines = redacted.split(separator: "\n", omittingEmptySubsequences: false)
    guard rows.count == lines.count, let width = rows.map(\.count).max(), width >= 20,
      rows.count(where: { $0.count == width }) >= 2
    else { return redacted }

    var changed = false
    var carried = false
    for index in rows.indices {
      if carried {
        let run = lines[index].prefix(while: isTokenCharacter)
        // It goes on down only if the whole row was token, to the edge.
        carried = !run.isEmpty && run.count == lines[index].count && rows[index].count == width
        if !run.isEmpty {
          lines[index] = "[redacted]" + lines[index].dropFirst(run.count)
          changed = true
        }
      }
      if !carried {
        carried = rows[index].count == width && rows[index] != lines[index] && markers.contains { lines[index].hasSuffix($0) }
      }
    }
    return changed ? lines.joined(separator: "\n") : redacted
  }

  // MARK: - Patterns

  /// `\b` is ASCII-simple throughout: the Unicode default treats `a.b` and
  /// `a:b` as one word, which would miss a key before `.txt` or after `id:`.
  /// A compiled `Regex` is never mutated, but isn't marked `Sendable`, hence
  /// `nonisolated(unsafe)`.

  /// A PEM private key, through its END line or to the end of the text when
  /// the rest has scrolled off the screen.
  nonisolated(unsafe) private static let privateKeyBlock =
    /-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----(?:(?!-----END)[\s\S])*(?:-----END (?:[A-Z ]+ )?PRIVATE KEY-----|\z)/

  /// `KEY=value`, `KEY: value` or `"key": "value"` where the name contains
  /// key, token, secret or password. `token`, `secret` and `password` count
  /// as names on their own; a bare `key` doesn't ("Press any key: …").
  /// A quoted value may have spaces in it. `lead` is the name and separator,
  /// kept as they were; `full` is the whole match; only the value is
  /// replaced, and only if `isSecret` says it's long enough. The name is
  /// bounded for the reason the URL scheme below is: unbounded, a long run
  /// of dotted or hyphenated words took seconds.
  nonisolated(unsafe) private static let secretAssignment =
    #/(?<full>(?<lead>\b(?:[A-Za-z_][A-Za-z0-9_.-]{0,60}?key|(?:[A-Za-z_][A-Za-z0-9_.-]{0,60}?)?(?:token|secret|password|passwd))[A-Za-z0-9_.-]{0,60}"?[ \t]*[=:][ \t]*)(?:"(?<doubleQuoted>[^"\n]{4,})"|'(?<singleQuoted>[^'\n]{4,})'|(?<bare>[^\s"']{4,})))/#
    .ignoresCase().wordBoundaryKind(.simple)

  /// What stands where a password would, and isn't one.
  private static let placeholders: Set<String> = [
    "none", "(none)", "null", "nil", "true", "false", "yes", "no", "unset", "empty", "<none>", "<empty>",
  ]

  /// Whether a named value is worth hiding: 8 characters or more, or, for a
  /// password, which is often shorter, 4 or more that aren't a placeholder
  /// or a row of asterisks.
  private static func isSecret(_ value: Substring, named name: Substring) -> Bool {
    if value.count >= 8 { return true }
    guard name.lowercased().contains("pass") else { return false }
    return !placeholders.contains(value.lowercased()) && !value.allSatisfy { "*•·.-x".contains($0) }
  }

  /// A secret passed as a command-line flag's own argument: `--password
  /// hunter2`, `--api-key abc123`. The flag's name ends in the secret word, so
  /// `--token-file path` and `--max-tokens 4000` are left alone.
  nonisolated(unsafe) private static let secretFlag =
    /((?:^|[ \t])--?[A-Za-z0-9-]{0,40}?(?:password|passwd|token|secret|api-?key)[ \t]+)(?!-)[^\s"']{6,}/
    .ignoresCase().anchorsMatchLineEndings()

  /// `scheme://user:password@host`; the user stays so the host is still readable.
  /// The scheme is bounded: an unbounded one backtracks from every character
  /// of a long unbroken token, taking 25 s on 40,000 characters, and an
  /// unwrapped read can carry a line that long.
  nonisolated(unsafe) private static let urlPassword =
    /(\b[A-Za-z][A-Za-z0-9+.-]{0,30}:\/\/[^\s\/:@]+:)[^\s\/@]+@/.wordBoundaryKind(.simple)

  /// `curl -u user:password`; the user stays.
  nonisolated(unsafe) private static let userPassword =
    /(\bcurl\b[^\n]{0,400}?[ \t](?:-u|--user)[ \t]+["']?[^\s:"']+:)[^\s"']+/.wordBoundaryKind(.simple)

  /// `mysql -pPASSWORD`, where the password follows the flag with no space.
  nonisolated(unsafe) private static let mysqlPassword =
    /(\b(?:mysql|mysqldump|mysqladmin|mariadb)\b[^\n]{0,400}?[ \t]-p)[^\s]{4,}/.wordBoundaryKind(.simple)

  nonisolated(unsafe) private static let bearer = /(\bbearer[ \t]+)[A-Za-z0-9\-._~+\/]{8,}=*/.ignoresCase().wordBoundaryKind(.simple)

  /// `Authorization: Basic …`. Only in that header: "basic" before a long
  /// word is ordinary English.
  nonisolated(unsafe) private static let basic =
    /(\bauthorization["']?[ \t]*[:=][ \t]*["']?basic[ \t]+)[A-Za-z0-9+\/]{8,}=*/.ignoresCase().wordBoundaryKind(.simple)

  /// A JWT, or its first two parts: the third may have wrapped onto the next row.
  nonisolated(unsafe) private static let jwt =
    /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{4,}(?:\.[A-Za-z0-9_-]+)?/.wordBoundaryKind(.simple)

  /// GitHub (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`), Slack
  /// (`xox?-`, `xapp-`), GitLab (`glpat-`), npm (`npm_`) and Hugging Face (`hf_`).
  nonisolated(unsafe) private static let prefixedToken =
    /\b(?:gh[opusr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abeprs]-[A-Za-z0-9-]{10,}|xapp-[A-Za-z0-9-]{10,}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{30,}|hf_[A-Za-z0-9]{30,})/
    .wordBoundaryKind(.simple)

  /// OpenAI and Anthropic (`sk-`), Stripe (`sk_live_`, `rk_live_` and their
  /// `_test_` twins), Google (`AIza`) and AWS access key ids (`AKIA`, `ASIA`).
  nonisolated(unsafe) private static let prefixedKey =
    /\b(?:sk-[A-Za-z0-9_-]{20,}|[sr]k_(?:live|test)_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{35,}|(?:AKIA|ASIA)[0-9A-Z]{16}\b)/
    .wordBoundaryKind(.simple)

  /// An AssemblyAI key: 32 hex standing alone, in either case.
  nonisolated(unsafe) private static let assemblyAIKey = /\b[0-9a-fA-F]{32}\b/.wordBoundaryKind(.simple)
}
