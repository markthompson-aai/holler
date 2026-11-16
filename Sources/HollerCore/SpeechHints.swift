import Foundation

/// Words worth biasing speech recognition toward: the names the user will say
/// to pick an agent ("the search one", "web-app") plus the tools involved.
public enum SpeechHints {
  public static let fixedTerms = ["Herdr", "Claude", "Codex", "Holler"]

  public static func keyTerms(for agents: [HerdrAgent]) -> [String] {
    var seen = Set<String>()
    var terms: [String] = []
    func add(_ term: String) {
      let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
      // Skip numbers ("1"), "~" and other labels nobody says aloud.
      guard trimmed.count >= 3, trimmed.contains(where: \.isLetter),
        seen.insert(trimmed.lowercased()).inserted
      else { return }
      terms.append(trimmed)
    }
    for agent in agents {
      add(agent.workspace)
      add(agent.tab)
      add(URL(fileURLWithPath: agent.cwd).lastPathComponent)
    }
    fixedTerms.forEach(add)
    return terms
  }

  public static let sttPrompt = """
    A software developer speaking to a voice assistant about the AI coding agents running in \
    their terminal: asking for status summaries, asking for an agent to be told to do something, or \
    asking for a new agent to be started.
    """
}
