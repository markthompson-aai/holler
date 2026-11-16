import Testing

@testable import HollerCore

@Suite struct NoteMarkdownTests {
  @Test func parsesTheShapesTheModelWrites() {
    let markdown = """
      **2 working, 4 idle.** Nothing is blocked.

      - **demo / main**: idle, tests passed.
      - **acme / tests**: working
        on the flaky test.
      1. numbered item
      ## Heading
      Trailing paragraph
      that wraps.
      """
    #expect(
      NoteBlock.parse(markdown) == [
        .paragraph("**2 working, 4 idle.** Nothing is blocked."),
        .bullet("**demo / main**: idle, tests passed."),
        .bullet("**acme / tests**: working on the flaky test."),
        .bullet("numbered item"),
        .heading("Heading"),
        .paragraph("Trailing paragraph that wraps."),
      ])
  }

  @Test func indentedBulletsNestUnderTheirParent() {
    let markdown = """
      - **product / 1**: idle. It flagged two things:
        - The docs contradict each other
          on streaming.
        * The connector is deprecated.
      - **web / 1**: working.
      """
    #expect(
      NoteBlock.parse(markdown) == [
        .bullet("**product / 1**: idle. It flagged two things:"),
        .subBullet("The docs contradict each other on streaming."),
        .subBullet("The connector is deprecated."),
        .bullet("**web / 1**: working."),
      ])
  }

  @Test func plainTextIsOneParagraph() {
    #expect(NoteBlock.parse("Which agent did you mean?") == [.paragraph("Which agent did you mean?")])
    #expect(NoteBlock.parse("\n\n").isEmpty)
  }
}

@Suite struct NoteAnswerTests {
  @Test func aSummaryBecomesAHeadlineAndOneRowPerAgent() {
    let markdown = """
      **2 working, 3 idle.** One needs a decision from you.

      - **demo / api**: needs you. Asks whether to drop the legacy `/v1` routes.
      - **demo / web**: working. Rebuilding the settings page.
      - **demo / infra**: idle. The staging deploy succeeded.
      """
    #expect(
      NoteAnswer.parse(markdown)
        == .summary(
          headline: "1 needs you, 1 working, 1 idle", subline: "One needs a decision from you.",
          agents: [
            AgentRow(name: "demo / api", state: .needsYou, update: "Asks whether to drop the legacy `/v1` routes."),
            AgentRow(name: "demo / web", state: .working, update: "Rebuilding the settings page."),
            AgentRow(name: "demo / infra", state: .idle, update: "The staging deploy succeeded."),
          ]))
  }

  @Test func blockedAgentsNeedYouToo() {
    let markdown = """
      **1 blocked.**

      - **demo / infra**: Blocked. Waiting for approval to run a script.
      - **demo / docs**: working
      """
    #expect(
      NoteAnswer.parse(markdown)
        == .summary(
          headline: "1 needs you, 1 working", subline: nil,
          agents: [
            AgentRow(name: "demo / infra", state: .needsYou, update: "Waiting for approval to run a script."),
            AgentRow(name: "demo / docs", state: .working, update: ""),
          ]))
  }

  /// The model's own headline can miscount or hedge ("0 need you by status,
  /// but…"); the note's is one clean count of the rows it shows.
  @Test func theHeadlineCountsTheRowsAndTheRowsSortByStatus() {
    let markdown = """
      **0 need you by status, but 2 are waiting on your reply.** Two asked you a question.

      - **demo / infra**: idle. The staging deploy succeeded.
      - **demo / web**: working. Rebuilding the settings page.
      - **demo / api**: needs you. Pick a fix.
      - **demo / docs**: idle. Wrote the guide.
      - **demo / ops**: needs you. Approve the script?
      """
    guard case .summary(let headline, let subline, let agents) = NoteAnswer.parse(markdown) else {
      Issue.record("not a summary")
      return
    }
    #expect(headline == "2 need you, 1 working, 2 idle")
    #expect(subline == "Two asked you a question.")
    #expect(agents.map(\.name) == ["demo / api", "demo / ops", "demo / web", "demo / infra", "demo / docs"])
  }

  @Test func anAgentNameSplitsIntoItsWorkspaceAndTab() {
    let row = AgentRow(name: "holler / coding-skills", state: .idle, update: "")
    #expect(row.workspace == "holler")
    #expect(row.tab == "coding-skills")
    let bare = AgentRow(name: "search", state: .idle, update: "")
    #expect(bare.workspace == nil)
    #expect(bare.tab == "search")
  }

  @Test func anythingElseStaysAsBlocks() {
    let oneAgent = "The **search** agent finished the fallback.\n\n- It added tests.\n- It updated the docs."
    #expect(NoteAnswer.parse(oneAgent) == .blocks(NoteBlock.parse(oneAgent)))
    let nested = "**1 idle.**\n\n- **demo / api**: idle. Flagged two things:\n  - The docs disagree."
    #expect(NoteAnswer.parse(nested) == .blocks(NoteBlock.parse(nested)))
    #expect(NoteAnswer.parse("Which agent did you mean?") == .blocks([.paragraph("Which agent did you mean?")]))
  }

  @Test func waitingOnYouNeedsYouAndAnUnknownStatusStaysAsBlocks() {
    #expect(
      NoteAnswer.parse("**1 waiting.**\n\n- **demo / api**: waiting on you. Pick a fix.")
        == .summary(
          headline: "1 needs you", subline: nil,
          agents: [AgentRow(name: "demo / api", state: .needsYou, update: "Pick a fix.")]))
    let unknown = "**Two things.**\n\n- **Docs**: they disagree on streaming.\n- **Tests**: 3 fail."
    #expect(NoteAnswer.parse(unknown) == .blocks(NoteBlock.parse(unknown)))
  }
}

