import Foundation
import Testing

@testable import HollerCore

@Suite struct AgentFilterTests {
  static let home = NSHomeDirectory()

  private func agent(in folder: String) -> HerdrAgent {
    HerdrAgent(paneId: "w1:p1", kind: "claude", status: "idle", workspace: "demo", tab: "acme", cwd: folder, title: "", focused: false)
  }

  /// A folder that really exists, with its symlinks resolved.
  private func folder(_ name: String) throws -> URL {
    try Fixtures.folder(name).resolvingSymlinksInPath()
  }

  // MARK: - How an excluded folder may be written

  @Test(arguments: [
    "\(home)/holler-secret", "~/holler-secret", "$HOME/holler-secret", "${HOME}/holler-secret", "\(home)/holler-secret/",
    "\(home)/Holler-Secret", "\(home)/holler-secret : /other", " /other: \(home)/holler-secret", "\(home)/x/../holler-secret",
  ])
  func aFolderIsHiddenHoweverItIsWritten(setting: String) {
    let filter = Settings(environment: ["HOLLER_EXCLUDE_PATHS": setting]).filter
    #expect(!filter.allows(agent(in: "\(Self.home)/holler-secret/acme")))
    #expect(!filter.allows(agent(in: "\(Self.home)/holler-secret")))
    #expect(!filter.allows(agent(in: "\(Self.home)/Holler-Secret/Acme")))
  }

  @Test func onlyTheFolderAndWhatIsUnderItAreHidden() {
    let filter = AgentFilter(excludedPathPrefixes: ["~/holler-secret"])
    #expect(filter.allows(agent(in: "\(Self.home)/holler-secrets")))
    #expect(filter.allows(agent(in: "\(Self.home)/work/holler-secret")))
    #expect(filter.allows(agent(in: Self.home)))
  }

  @Test func theFoldersInForceAreAbsolutePaths() {
    let filter = Settings(environment: ["HOLLER_EXCLUDE_PATHS": "~/holler-secret/ : $HOME/b:/c/../d"]).filter
    #expect(filter.excludedPathPrefixes == ["\(Self.home)/holler-secret", "\(Self.home)/b", "/d"])
  }

  @Test func twoFiltersFromTheSameSettingAreEqual() {
    let setting = ["HOLLER_EXCLUDE_PATHS": "~/a:~/b:/tmp/c:/var/d"]
    #expect(Settings(environment: setting).filter == Settings(environment: setting).filter)
  }

  @Test func anAgentWithNoFolderIsNotHidden() {
    let filter = AgentFilter(excludedPathPrefixes: ["/"])
    #expect(filter.allows(agent(in: "")))
    #expect(!filter.allows(agent(in: "/anywhere")))
  }

  // MARK: - Symlinks

  @Test func aFolderExcludedThroughASymlinkIsHiddenByItsRealPath() throws {
    let real = try folder("clients")
    let link = real.deletingLastPathComponent().appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let throughLink = AgentFilter(excludedPathPrefixes: [link.path])
    #expect(!throughLink.allows(agent(in: real.path + "/acme")))
    let byRealPath = AgentFilter(excludedPathPrefixes: [real.path])
    #expect(!byRealPath.allows(agent(in: link.path + "/acme")))
  }

  @Test func privateAndPlainTemporaryFoldersAreTheSameFolder() throws {
    // The system's temporary folder is /var/folders/…, a symlink to
    // /private/var/folders/…, which is what a process reports as its folder.
    let plain = try folder("clients").path
    #expect(plain.hasPrefix("/var/"))
    let reported = "/private" + plain

    #expect(!AgentFilter(excludedPathPrefixes: [plain]).allows(agent(in: reported)))
    #expect(!AgentFilter(excludedPathPrefixes: [plain]).allows(agent(in: reported + "/not-there-yet")))
    #expect(!AgentFilter(excludedPathPrefixes: [reported]).allows(agent(in: plain + "/acme")))
    #expect(!AgentFilter(excludedPathPrefixes: ["/private" + plain + "-gone"]).allows(agent(in: plain + "-gone/acme")))
  }

  @Test func aFolderThatDoesNotExistYetIsCheckedThroughTheFolderAboveIt() throws {
    let real = try folder("clients")
    let link = real.deletingLastPathComponent().appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let filter = AgentFilter(excludedPathPrefixes: [real.path])
    #expect(!filter.allowsFolder(link.path + "/new/worktree"))
    #expect(filter.allowsFolder(real.deletingLastPathComponent().path + "/elsewhere/worktree"))
  }

  @Test func anExcludedFolderInsideAnotherIsFound() throws {
    let repo = try folder("repo")
    let filter = AgentFilter(excludedPathPrefixes: [repo.path.uppercased() + "/customer-data"])
    #expect(filter.excludesFolder(inside: repo.path))
    #expect(!filter.excludesFolder(inside: repo.path + "/customer-data"))
    #expect(!filter.excludesFolder(inside: repo.path + "/src"))
  }

  // MARK: - Entries that hide nothing

  @Test func anEntryThatIsNotAnAbsolutePathIsLeftOutAndSaidSo() {
    let settings = Settings(environment: ["HOLLER_EXCLUDE_PATHS": "clients/acme:\(Self.home)"])
    #expect(settings.filter.excludedPathPrefixes == [Self.home])
    #expect(settings.filter.allows(agent(in: "/work/clients/acme")))
    #expect(settings.excludeProblems.count == 1)
    #expect(settings.excludeProblems[0].contains("\"clients/acme\" isn't an absolute path"))
    #expect(settings.problems == settings.excludeProblems)
  }

  @Test func anEntryThatDoesNotExistStillAppliesAndIsSaidSo() {
    let settings = Settings(environment: ["HOLLER_EXCLUDE_PATHS": "~/holler-no-such-folder"])
    #expect(!settings.filter.allows(agent(in: "\(Self.home)/holler-no-such-folder/acme")))
    #expect(settings.excludeProblems == [
      "HOLLER_EXCLUDE_PATHS: \(Self.home)/holler-no-such-folder doesn't exist, so check its spelling; it hides nothing until it does"
    ])
  }

  @Test func foldersThatExistRaiseNoProblem() {
    #expect(Settings(environment: ["HOLLER_EXCLUDE_PATHS": "~ : /tmp/"]).excludeProblems.isEmpty)
    #expect(Settings(environment: [:]).excludeProblems.isEmpty)
  }
}
