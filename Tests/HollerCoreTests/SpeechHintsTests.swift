import Testing

@testable import HollerCore

@Suite struct SpeechHintsTests {
  @Test func keyTermsComeFromLabelsAndFoldersWithoutNoise() {
    let agents = [
      HerdrAgent(
        paneId: "w1:p1", kind: "claude", status: "idle", workspace: "AssemblyAI", tab: "search",
        cwd: "/Users/test/Desktop/AssemblyAI", title: "", focused: false),
      HerdrAgent(
        paneId: "w2:p1", kind: "claude", status: "idle", workspace: "~", tab: "1",
        cwd: "/Users/test/Projects/web-app", title: "", focused: false),
    ]
    #expect(
      SpeechHints.keyTerms(for: agents)
        == ["AssemblyAI", "search", "web-app", "Herdr", "Claude", "Codex", "Holler"])
  }
}
