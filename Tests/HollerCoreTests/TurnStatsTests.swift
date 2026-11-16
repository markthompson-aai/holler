import Foundation
import Testing

@testable import HollerCore

@Suite struct TurnStatsTests {
  /// A line as `log show --style compact` prints it, from a spoken, read-aloud request.
  static let logged =
    "2026-10-29 11:19:47.939 Df Holler[70124:14895d] [com.assemblyai.holler:Turn] turn totalMs=13949 transcriptMs=985 "
    + "herdrMs=1 readMs=119 readOnRelease=true agentsRead=14 events=live modelMs=12158 roundMs=3301,8857 toolsMs=804 rounds=2 "
    + "tools=read_agents tokensIn=43505 tokensCached=5058 tokensOut=1297 actions=0 jumped=false readAloud=true "
    + "request=a008296f-12c1-4991-a22d-e0001dfe025b"

  /// The line the controller writes, with nothing in front of it.
  static let bare =
    "turn totalMs=4640 transcriptMs=812 herdrMs=2 readMs=48 readOnRelease=true agentsRead=3 events=off modelMs=3400 "
    + "roundMs=2900,500 toolsMs=410 rounds=2 tools=list_agents,prompt_agent "
    + "tokensIn=5200 tokensCached=3100 tokensOut=140 actions=1 jumped=false readAloud=false request=req_2"

  static let failed =
    "2026-10-29 11:30:02.100 Df Holler[70124:14895d] [com.assemblyai.holler:Turn] turn failed totalMs=2000 transcriptMs=n/a "
    + "error=LLM Gateway returned 502: Bad Gateway"

  /// Written before the `tools` field existed.
  static let older =
    "turn totalMs=3820 transcriptMs=n/a herdrMs=301 modelMs=3400 roundMs=3400 toolsMs=111 rounds=1 "
    + "tokensIn=5200 tokensCached=3100 tokensOut=140 actions=0 jumped=true readAloud=false request=req_1"

  /// A typed request that used no tools, with its stage times in whole seconds.
  static func typed(total: Int, model: Int, rounds: Int = 1, tools: String = "none", extra: String = "") -> String {
    "turn totalMs=\(total * 1000) transcriptMs=n/a herdrMs=10 readMs=50 readOnRelease=false agentsRead=2 events=live "
      + "modelMs=\(model * 1000) roundMs=\(model * 1000) toolsMs=20 rounds=\(rounds) tools=\(tools) "
      + "tokensIn=1000 tokensCached=500 tokensOut=100 actions=0 jumped=false readAloud=false request=r\(extra)"
  }

  // MARK: - Reading lines

  @Test func aLoggedLineParsesIntoItsFields() throws {
    let record = try #require(TurnRecord.parse(Self.logged))
    #expect(record.loggedAt == "2026-10-29 11:19")
    #expect(record.failed == false)
    #expect(record.milliseconds("totalMs") == 13949)
    #expect(record.milliseconds("transcriptMs") == 985)
    #expect(record.milliseconds("modelMs") == 12158)
    #expect(record.int("rounds") == 2)
    #expect(record.int("tokensIn") == 43505)
    #expect(record.fields["readAloud"] == "true")
    #expect(record.fields["events"] == "live")
    #expect(record.tools == [TurnRecord.Tool(name: "read_agents", failed: false)])
  }

  @Test func aBareLineParsesToo() throws {
    let record = try #require(TurnRecord.parse(Self.bare))
    #expect(record.loggedAt == nil)
    #expect(record.milliseconds("totalMs") == 4640)
    #expect(record.tools?.map(\.name) == ["list_agents", "prompt_agent"])
  }

  @Test func aFailedToolIsMarked() throws {
    let record = try #require(TurnRecord.parse(Self.bare.replacingOccurrences(of: "prompt_agent", with: "close_tab!")))
    #expect(record.tools == [.init(name: "list_agents", failed: false), .init(name: "close_tab", failed: true)])
  }

  @Test func aFailedLineKeepsItsWholeError() throws {
    let record = try #require(TurnRecord.parse(Self.failed))
    #expect(record.failed)
    #expect(record.milliseconds("totalMs") == 2000)
    #expect(record.milliseconds("transcriptMs") == nil)
    #expect(record.error == "LLM Gateway returned 502: Bad Gateway")
  }

  @Test func anOlderLineHasNoToolsToCount() throws {
    let record = try #require(TurnRecord.parse(Self.older))
    #expect(record.tools == nil)
    #expect(record.milliseconds("readMs") == nil)
  }

  @Test func noToolsIsAnEmptyList() throws {
    let record = try #require(TurnRecord.parse(Self.typed(total: 3, model: 2)))
    #expect(record.tools == [])
  }

  @Test func otherLinesAreSkipped() {
    let text = """
      Timestamp               Ty Process[PID:TID]
      \(Self.logged)
      2026-10-29 11:20:00.000 Df Holler[70124:14895d] [com.assemblyai.holler:Other] turn of phrase
      \(Self.failed)

      Log      - Default:          2, Info:                0, Debug:             0, Error:          0, Fault:          0
      """
    let records = TurnLog.records(in: text)
    #expect(records.count == 2)
    #expect(records.map(\.failed) == [false, true])
  }

  @Test func aWindowIsMinutesHoursOrDays() {
    #expect(TurnLog.window("7d") == .seconds(7 * 86_400))
    #expect(TurnLog.window("24h") == .seconds(24 * 3_600))
    #expect(TurnLog.window("30m") == .seconds(30 * 60))
    for bad in ["7", "d", "7w", "1.5h", "", "7 d", "-1d"] { #expect(TurnLog.window(bad) == nil, "\(bad)") }
  }

  // MARK: - Summing up

  @Test func eachStageGetsItsPercentilesAndMax() throws {
    // Totals 1 s to 20 s; the model takes half of each.
    let lines = (1...20).map { Self.typed(total: $0, model: $0 / 2) }
    let stats = TurnStats(TurnLog.records(in: lines.joined(separator: "\n")))
    #expect(stats.answered == 20)
    #expect(stats.failed == 0)
    let total = try #require(stats.stages.first { $0.name == "total" })
    #expect(total.count == 20)
    #expect(total.p50 == .seconds(10))
    #expect(total.p95 == .seconds(19))
    #expect(total.max == .seconds(20))
    let model = try #require(stats.stages.first { $0.name == "model" })
    #expect(model.p50 == .seconds(5))
    #expect(model.max == .seconds(10))
  }

  @Test func theStagesComeInTheOrderOfATurn() {
    let stats = TurnStats([TurnRecord.parse(Self.logged)!, TurnRecord.parse(Self.bare)!])
    #expect(stats.stages.map(\.name) == ["total", "transcript", "herdr", "read", "model", "tools"])
  }

  @Test func aStageNobodyLoggedIsLeftOut() {
    let without = TurnStats([TurnRecord.parse(Self.bare)!])
    #expect(!without.stages.contains { $0.name == "speech" })
    let with = TurnStats([TurnRecord.parse(Self.bare)!, TurnRecord.parse(Self.bare + " speechMs=400")!])
    let speech = with.stages.first { $0.name == "speech" }
    #expect(speech?.count == 1)
    #expect(speech?.max == .milliseconds(400))
  }

  @Test func typedTurnsHaveNoTranscriptToCount() throws {
    let stats = TurnStats(TurnLog.records(in: [Self.logged, Self.typed(total: 3, model: 2)].joined(separator: "\n")))
    let transcript = try #require(stats.stages.first { $0.name == "transcript" })
    #expect(transcript.count == 1)
    #expect(transcript.max == .milliseconds(985))
  }

  @Test func failedTurnsAreCountedButNotTimed() throws {
    let stats = TurnStats(TurnLog.records(in: [Self.logged, Self.failed].joined(separator: "\n")))
    #expect(stats.answered == 1)
    #expect(stats.failed == 1)
    let total = try #require(stats.stages.first { $0.name == "total" })
    #expect(total.count == 1)
  }

  @Test func tokensAreSummedAcrossTurns() {
    let stats = TurnStats([TurnRecord.parse(Self.logged)!, TurnRecord.parse(Self.bare)!])
    #expect(stats.tokensIn == 43505 + 5200)
    #expect(stats.tokensCached == 5058 + 3100)
    #expect(stats.tokensOut == 1297 + 140)
  }

  @Test func roundsAreTalliedInOrder() {
    let lines = [Self.typed(total: 2, model: 1, rounds: 3), Self.typed(total: 2, model: 1), Self.typed(total: 2, model: 1, rounds: 2),
      Self.typed(total: 2, model: 1)]
    let stats = TurnStats(TurnLog.records(in: lines.joined(separator: "\n")))
    #expect(stats.rounds == [.init(rounds: 1, turns: 2), .init(rounds: 2, turns: 1), .init(rounds: 3, turns: 1)])
  }

  @Test func eachToolCountsOncePerTurnMostUsedFirst() {
    let lines = [
      Self.typed(total: 2, model: 1, tools: "read_agents,read_agents,prompt_agent"),
      Self.typed(total: 2, model: 1, tools: "read_agents"),
      Self.typed(total: 2, model: 1, tools: "close_tab!"),
      Self.typed(total: 2, model: 1),
      Self.older,
    ]
    let stats = TurnStats(TurnLog.records(in: lines.joined(separator: "\n")))
    #expect(
      stats.tools == [
        .init(name: "read_agents", turns: 2, failed: 0), .init(name: "close_tab", turns: 1, failed: 1),
        .init(name: "prompt_agent", turns: 1, failed: 0),
      ])
    #expect(stats.withoutTools == 1)
  }

  @Test func theSpanIsTheFirstAndLastTimeLogged() {
    let stats = TurnStats(TurnLog.records(in: [Self.logged, Self.failed].joined(separator: "\n")))
    #expect(stats.first == "2026-10-29 11:19")
    #expect(stats.last == "2026-10-29 11:30")
    #expect(TurnStats([TurnRecord.parse(Self.bare)!]).first == nil)
  }

  // MARK: - The table

  @Test func theTableReadsCompactly() {
    let stats = TurnStats(TurnLog.records(in: [Self.logged, Self.bare, Self.failed].joined(separator: "\n")))
    let expected = """
      3 turns in the last 7d, 1 failed
                       p50     p95     max
      total          4.64s  13.95s  13.95s
      transcript     0.81s   0.99s   0.99s
      herdr          0.00s   0.00s   0.00s
      read           0.05s   0.12s   0.12s
      model          3.40s  12.16s  12.16s
      tools          0.41s   0.80s   0.80s
      tokens      in 48705 · cached 8158 · out 1437
      rounds      2 ×2
      tools used  list_agents ×1 · prompt_agent ×1 · read_agents ×1
      """
    #expect(stats.table(window: "7d") == expected)
  }

  @Test func theTableSaysWhenItSpansAndWhatFailed() {
    let lines = [Self.logged, Self.failed, Self.typed(total: 3, model: 2, tools: "close_tab!"), Self.typed(total: 2, model: 1)]
    let table = TurnStats(TurnLog.records(in: lines.joined(separator: "\n"))).table(window: nil)
    #expect(table.hasPrefix("4 turns from 2026-10-29 11:19 to 2026-10-29 11:30, 1 failed\n"))
    #expect(table.hasSuffix("tools used  close_tab ×1 (1 failed) · read_agents ×1 · none ×1"))
  }

  @Test func linesFromBeforeToolsWereLoggedSaySo() {
    let table = TurnStats([TurnRecord.parse(Self.older)!]).table(window: "7d")
    #expect(table.hasSuffix("tools used  not logged by this build"))
  }

  @Test func noTurnsIsSaidPlainly() {
    #expect(TurnStats([]).table(window: "24h") == "No turns in the last 24h.")
    #expect(TurnStats([]).table(window: nil) == "No turns.")
  }
}
