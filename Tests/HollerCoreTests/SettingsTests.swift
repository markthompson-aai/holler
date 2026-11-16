import Foundation
import Testing

@testable import HollerCore

@Suite struct SettingsTests {
  // MARK: - Hotkey

  @Test func theHotkeyIsRightOptionUnlessSet() {
    let settings = Settings(environment: [:])
    #expect(settings.hotkey == .rightOption)
    #expect(settings.hotkeyProblem == nil)
  }

  @Test(arguments: [
    ("right-option", Settings.Hotkey.rightOption), ("right-command", .rightCommand), ("fn", .function),
    ("Right-Command", .rightCommand), (" fn ", .function),
  ])
  func eachKeyIsNamedPlainly(name: String, key: Settings.Hotkey) {
    let settings = Settings(environment: ["HOLLER_HOTKEY": name])
    #expect(settings.hotkey == key)
    #expect(settings.hotkeyProblem == nil)
  }

  @Test func anUnknownKeyFallsBackToRightOptionAndSaysSo() throws {
    let settings = Settings(environment: ["HOLLER_HOTKEY": "left-option"])
    #expect(settings.hotkey == .rightOption)
    let problem = try #require(settings.hotkeyProblem)
    #expect(problem.contains("left-option"))
    #expect(problem.contains("right-option, right-command, fn"))
    #expect(problem.contains("right ⌥"))
  }

  @Test func anEmptyKeyIsTheDefaultWithoutComplaint() {
    let settings = Settings(environment: ["HOLLER_HOTKEY": "  "])
    #expect(settings.hotkey == .rightOption)
    #expect(settings.hotkeyProblem == nil)
  }

  @Test func eachKeyHasItsNames() {
    #expect(Settings.Hotkey.rightOption.label == "right ⌥")
    #expect(Settings.Hotkey.rightOption.symbol == "⌥")
    #expect(Settings.Hotkey.rightOption.spokenName == "right Option")
    #expect(Settings.Hotkey.rightCommand.label == "right ⌘")
    #expect(Settings.Hotkey.rightCommand.spokenName == "right Command")
    #expect(Settings.Hotkey.function.label == "fn")
    #expect(Settings.Hotkey.function.symbol == "fn")
    #expect(Settings.Hotkey.function.spokenName == "fn")
  }

  // MARK: - Effort

  @Test(arguments: [("low", "low"), ("XHigh", "xhigh"), (" max ", "max"), ("medium", "medium")])
  func eachEffortLevelIsTakenAsNamed(name: String, effort: String) {
    let settings = Settings(environment: ["HOLLER_EFFORT": name])
    #expect(settings.effort == effort)
    #expect(settings.effortProblem == nil)
  }

  @Test func defaultLeavesTheEffortToTheModel() {
    let settings = Settings(environment: ["HOLLER_EFFORT": "Default"])
    #expect(settings.effort == nil)
    #expect(settings.effortProblem == nil)
  }

  @Test func anUnknownEffortFallsBackToMediumAndSaysSo() {
    let settings = Settings(environment: ["HOLLER_EFFORT": "turbo"])
    #expect(settings.effort == "medium")
    #expect(
      settings.problems == [
        "HOLLER_EFFORT=turbo isn't an effort level Holler knows (low, medium, high, xhigh, max, default); using medium"
      ])
  }

  // MARK: - What a reload changes

  @Test func changesNameTheSettingsThatDiffer() {
    let before = Settings(environment: ["ASSEMBLYAI_API_KEY": "k1", "HOLLER_MODEL": "a"])
    let after = Settings(environment: [
      "ASSEMBLYAI_API_KEY": "k2", "HOLLER_MODEL": "b", "HOLLER_EFFORT": "high", "HOLLER_VOICE": "Zoe",
      "HOLLER_WORKSPACES": "demo", "HOLLER_HOTKEY": "fn",
    ])
    #expect(after.changes(from: before) == ["API key", "model", "effort", "voice", "filter", "hotkey"])
    #expect(before.changes(from: before).isEmpty)
  }

  @Test func settingsCompareEqualWhenNothingDiffers() {
    let environment = ["ASSEMBLYAI_API_KEY": "k", "HOLLER_EXCLUDE_PATHS": "/a:/b"]
    #expect(Settings(environment: environment) == Settings(environment: environment))
    #expect(Settings(environment: environment) != Settings(environment: ["ASSEMBLYAI_API_KEY": "k"]))
  }

  // MARK: - Applying new settings to the running objects

  @Test func theSessionUsesTheNewModelAndEffortOnItsNextRequest() async throws {
    let gateway = FakeGateway([Fixtures.answer("one"), Fixtures.answer("two")])
    let session = AssistantSession(
      gateway: gateway, herdr: Fixtures.client(FakeRunner()),
      configuration: .init(model: "old-model", effort: "medium", prefetchLines: 0))
    _ = try await session.ask("first")
    await session.update(model: "new-model", effort: nil)
    _ = try await session.ask("second")

    #expect(gateway.requests.map(\.model) == ["old-model", "new-model"])
    #expect(gateway.requests.map(\.effort) == ["medium", nil])
  }

  @Test func theSessionKeepsItsConversationAcrossAnUpdate() async throws {
    let gateway = FakeGateway([Fixtures.answer("one"), Fixtures.answer("two")])
    let session = AssistantSession(
      gateway: gateway, herdr: Fixtures.client(FakeRunner()), configuration: .init(model: "m", prefetchLines: 0))
    _ = try await session.ask("first")
    await session.update(model: "m2", effort: nil)
    _ = try await session.ask("second")

    let remembered = try #require(gateway.requests.last?.messages)
    #expect(remembered.contains { $0.role == .assistant && $0.content == "one" })
  }

  @Test func theSessionSendsThroughANewGatewayWhenGivenOne() async throws {
    let first = FakeGateway([Fixtures.answer("one")])
    let second = FakeGateway([Fixtures.answer("two")])
    let session = AssistantSession(
      gateway: first, herdr: Fixtures.client(FakeRunner()), configuration: .init(model: "m", prefetchLines: 0))
    _ = try await session.ask("first")
    await session.update(model: "m", effort: nil, gateway: second)
    let turn = try await session.ask("second")

    #expect(turn.answer == "two")
    #expect(first.requests.count == 1 && second.requests.count == 1)
  }

  @MainActor @Test func theControllersNextRequestUsesTheNewSettingsInTheSameConversation() async throws {
    let old = FakeGateway([Fixtures.answer("one")])
    let new = FakeGateway([Fixtures.answer("two")])
    let controller = controller(old)
    controller.ask("first")
    await controller.settle()

    controller.updateSession(model: "new-model", effort: "high", gateway: new)
    controller.ask("second")
    await controller.settle()

    #expect(old.requests.map(\.model) == ["old-model"])
    let request = try #require(new.requests.first)
    #expect(request.model == "new-model" && request.effort == "high")
    #expect(request.messages.contains { $0.role == .assistant && $0.content == "one" })
    #expect(controller.exchanges.last?.answer == "two")
  }

  @MainActor @Test func aSessionMadeAfterAReloadStartsWithTheNewSettings() async throws {
    let old = FakeGateway([])
    let new = FakeGateway([Fixtures.answer("ok")])
    let controller = controller(old)

    controller.updateSession(model: "new-model", effort: nil, gateway: new)
    controller.ask("first")
    await controller.settle()

    #expect(old.requests.isEmpty)
    #expect(new.requests.map(\.model) == ["new-model"])
  }

  @MainActor @Test func theControllerNamesTheConfiguredKey() async {
    let controller = controller(FakeGateway([Fixtures.answer("hi")]), voice: FakeVoice(transcript: " "))
    controller.hotkey = .function
    controller.ask("summarise")
    await controller.settle()
    controller.hotkeyDown()
    controller.hotkeyUp()
    await controller.settle()

    #expect(controller.notice == "Didn't catch that. Hold fn and try again.")
  }

  @MainActor func controller(_ gateway: FakeGateway, voice: FakeVoice = FakeVoice()) -> AssistantController {
    let herdr = Fixtures.client(FakeRunner())
    return AssistantController(voice: voice, herdr: herdr, tapThreshold: .zero) {
      AssistantSession(
        gateway: gateway, herdr: herdr, configuration: .init(model: "old-model", effort: "medium", prefetchLines: 0))
    }
  }

  @Test func aNewFilterReachesEveryCopyOfTheClient() async throws {
    let herdr = Fixtures.client(FakeRunner())
    let copy = herdr
    #expect(try await copy.agents().count == 2)

    herdr.update(filter: AgentFilter(workspaces: ["demo"]))

    #expect(try await copy.agents().map(\.paneId) == ["w1:p1"])
    herdr.update(filter: AgentFilter(excludedPathPrefixes: ["/Users/test/Projects"]))
    #expect(try await herdr.agents().map(\.paneId) == ["w2:p1"])
  }
}
