import AVFoundation
import AppKit
import BlurtEngine
import OSLog
import Synchronization
import HollerCore
import HollerSpeech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
  private var controller: AssistantController?
  private var notePanel: NotePanelController?
  private var announcer: NoteAnnouncer?
  private var hotkey: HotkeyTap?
  private let level = LevelModel()
  private var statusItem: NSStatusItem?
  private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
  private var setupProblem: SetupProblem?
  private var keyWindow: APIKeyWindowController?
  /// What's running now, and what a reload compares against.
  private var settings: Settings?
  private var herdr: HerdrClient?
  private var watcher: HerdrWatcher?
  private var gateway: LLMGateway?
  /// Read by speech in and out on every request, so a reload's key reaches them.
  private let apiKey = CurrentKey()
  private var macVoice: MacVoice?
  private var envWatchers: [EnvFileWatcher] = []
  private static let turnLog = Logger(subsystem: "com.assemblyai.holler", category: "Turn")
  private static let settingsLog = Logger(subsystem: "com.assemblyai.holler", category: "Settings")

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = Self.editingMenu()
    installStatusItem()
    setUp(Self.loadSettings(), alert: true)
    // A watcher waits for a missing file to appear, so a settings file
    // created after launch is read when it's saved.
    envWatchers = Self.envFileCandidates.map { url in
      let watcher = EnvFileWatcher(url: url) { [weak self] in self?.reload(from: "file") }
      watcher.start()
      return watcher
    }
  }

  /// Builds Holler from `settings`, or says what's missing. With `alert`,
  /// a missing key opens the key window and a missing Herdr an alert;
  /// without it, only the menu says so.
  private func setUp(_ settings: Settings, alert: Bool) {
    for problem in settings.problems { Self.settingsLog.error("\(problem, privacy: .public)") }
    guard let apiKey = settings.apiKey else {
      return fail(.noKey, alert: alert)
    }
    guard let herdrPath = settings.herdrPath else {
      return fail(.noHerdr, alert: alert)
    }
    setupProblem = nil
    self.settings = settings
    self.apiKey.value = apiKey

    let herdr = HerdrClient(executable: herdrPath, filter: settings.filter, startedTabsFile: Self.startedTabsFile)
    self.herdr = herdr
    // Follows Herdr's events for wait times and what changed; if they stop,
    // requests carry on from snapshots alone. What it has seen is kept on
    // disk, so a relaunch carries on where it left off.
    let watcher = HerdrWatcher(herdr: herdr, source: HerdrSocket.locate(), file: Self.herdrHistoryFile)
    self.watcher = watcher
    Task { await watcher.start() }
    Task {
      for await count in await watcher.needsYouCounts() { showNeedsYou(count) }
    }
    let gateway = LLMGateway(apiKey: apiKey)
    self.gateway = gateway
    let key = self.apiKey
    let voice = BlurtVoiceInput(speech: SpeechInput(apiKey: { key.value }))
    let macVoice = MacVoice(preferred: settings.voice)
    self.macVoice = macVoice
    let (model, effort) = (settings.model, settings.effort)
    let speaker = Speaker.make(apiKey: { key.value }, macVoice: macVoice)
    let controller = AssistantController(voice: voice, speaker: speaker, herdr: herdr) {
      AssistantSession(gateway: gateway, herdr: herdr, watcher: watcher, configuration: .init(model: model, effort: effort))
    }
    controller.onListeningStarted = { Sounds.play(.start) }
    controller.onListeningEnded = { Sounds.play(.stop) }
    controller.onJumped = { _ in HerdrTerminal.bringToFront() }
    // Notice level, so macOS keeps the lines on disk for `log show`.
    controller.onTiming = { Self.turnLog.notice("\($0, privacy: .public)") }
    controller.runsSimpleActionsWithoutACard = UserDefaults.standard.bool(forKey: Self.runsSimpleActionsKey)
    // On until switched off: a missing default means on.
    controller.readsAnswersAloud = UserDefaults.standard.object(forKey: Self.readsAnswersAloudKey) as? Bool ?? true
    self.controller = controller
    notePanel = NotePanelController(controller: controller, level: level)
    announcer = NoteAnnouncer(controller: controller)

    let level = level
    Task {
      await voice.warmUp()
      for await value in voice.levels { level.level = value }
    }
    requestMicrophone()
    installHotkey(settings.hotkey)
  }

  // MARK: - Reloading settings

  @objc private func reloadSettings() {
    reload(from: "menu")
  }

  /// Reads `.env`, the environment and the Keychain again and applies what
  /// changed, in one log line. Before Holler is set up, it tries setting up
  /// again, saying what's still missing unless the trigger was a file save.
  private func reload(from trigger: String) {
    let new = Self.loadSettings()
    guard let old = settings, controller != nil else {
      Self.settingsLog.notice("Reloaded settings from the \(trigger, privacy: .public): setting up")
      setUp(new, alert: trigger != "file")
      return
    }
    let changed = new.changes(from: old)
    Self.settingsLog.notice(
      "Reloaded settings from the \(trigger, privacy: .public): \(changed.isEmpty ? "nothing changed" : changed.joined(separator: ", ") + " changed", privacy: .public)"
    )
    for problem in new.problems { Self.settingsLog.error("\(problem, privacy: .public)") }
    apply(new, over: old)
  }

  /// Hands new settings to the running objects, for the next request:
  /// the session keeps its conversation and the Herdr watcher keeps going,
  /// unless the filter changed, which starts both afresh.
  /// Only the gateway, when the API key changes, and the hotkey's tap, when
  /// the hotkey does, are made afresh. A new herdr path waits for a relaunch.
  private func apply(_ new: Settings, over old: Settings) {
    guard let controller, let herdr, var gateway else { return }
    var applied = new
    if let key = new.apiKey {
      if key != old.apiKey {
        apiKey.value = key
        gateway = LLMGateway(apiKey: key)
        self.gateway = gateway
      }
    } else {
      Self.settingsLog.error("The API key is gone from the settings and the Keychain; keeping the key Holler started with")
      applied.apiKey = old.apiKey
    }
    controller.updateSession(model: new.model, effort: new.effort, gateway: gateway)
    if new.voice != old.voice { macVoice?.prefer(new.voice) }
    if new.filter != old.filter {
      herdr.update(filter: new.filter)
      // The watcher is subscribed to the agents the old filter allowed, and
      // the conversation may be about agents the new one hides: subscribe
      // afresh, which also drops them from the count in the menu bar, and
      // start a new conversation, so nothing remembered about them is sent.
      if let watcher {
        Task {
          await watcher.stop()
          await watcher.start()
        }
      }
      controller.newConversation()
    }
    if new.herdrPath != old.herdrPath {
      Self.settingsLog.notice("A new herdr path takes effect when Holler relaunches")
      applied.herdrPath = old.herdrPath
    }
    if new.hotkey != old.hotkey { installHotkey(new.hotkey) }
    settings = applied
  }

  private var lastGatewayWarmUp: ContinuousClock.Instant?

  /// While you're still talking, make sure the connection to LLM Gateway is
  /// open, so the question doesn't wait on a TLS handshake. Pooled connections
  /// idle out, so refresh at most every 30 s.
  private func warmGateway() {
    guard let gateway else { return }
    let now = ContinuousClock.now
    if let last = lastGatewayWarmUp, now - last < .seconds(30) { return }
    lastGatewayWarmUp = now
    Task { await gateway.warmUp() }
  }

  // MARK: - Permissions

  private func requestMicrophone() {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
      AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }
  }

  /// Listens for `key`, in place of any key before it. The hotkey needs Input
  /// Monitoring: ask once, then keep retrying quietly until it's granted in
  /// System Settings.
  private func installHotkey(_ key: Settings.Hotkey) {
    guard let controller else { return }
    hotkey?.stop()
    controller.hotkey = key
    let level = level
    let tap = HotkeyTap(
      key: key,
      onPress: { [weak self] in
        level.level = 0
        controller.hotkeyDown()
        self?.warmGateway()
      },
      onRelease: { controller.hotkeyUp() },
      onCancel: { controller.hotkeyCancelled() })
    hotkey = tap
    if tap.ensureRunning() { return refreshStatusLine() }
    if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
    refreshStatusLine()
    Task { [weak self] in
      while true {
        try? await Task.sleep(for: .seconds(2))
        // A reload may have put another key's tap in its place.
        guard let self, hotkey === tap else { return }
        if tap.ensureRunning() { return refreshStatusLine() }
      }
    }
  }

  /// The menu's first line: the permission Holler is still missing and
  /// where to grant it, or else how to ask. Brought up to date each time the
  /// menu opens, since either permission can change in System Settings
  /// while Holler runs.
  private func refreshStatusLine() {
    guard setupProblem == nil, let hotkey else { return }
    if !hotkey.isInstalled {
      statusLine.title = "Needs Input Monitoring permission…"
    } else if MicrophonePermission.problem != nil {
      statusLine.title = "Needs the microphone: System Settings › Privacy & Security › Microphone"
    } else {
      statusLine.title = "Hold \(hotkey.key.label) to ask about your agents"
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    refreshStatusLine()
  }

  // MARK: - Menu bar

  /// Holler never shows a menu bar of its own, but text fields take ⌘V, ⌘C
  /// and the rest from the main menu's key equivalents. Without this menu, a
  /// key can be typed into the key window or Type a Question… but not pasted.
  /// While the note holds the keyboard nothing answers these actions, so the
  /// items stay disabled and the keys reach the note as before.
  private static func editingMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let main = NSMenu()
    // The first item is the application menu; Holler's lives in the status item.
    main.addItem(NSMenuItem())
    let editItem = NSMenuItem()
    editItem.submenu = edit
    main.addItem(editItem)
    return main
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = MarkView.menuBarImage()
    let menu = NSMenu()
    statusLine.isEnabled = false
    menu.addItem(statusLine)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Summarise My Agents", action: #selector(summarise), keyEquivalent: "")
    menu.addItem(withTitle: "Type a Question…", action: #selector(typeQuestion), keyEquivalent: "")
    menu.addItem(withTitle: "Reopen Last Note", action: #selector(reopenNote), keyEquivalent: "")
    menu.addItem(withTitle: "Close Note", action: #selector(closeNote), keyEquivalent: "")
    menu.addItem(withTitle: "New Conversation", action: #selector(newConversation), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Read Answers Aloud", action: #selector(toggleReadAloud), keyEquivalent: "")
    menu.addItem(withTitle: "Run Simple Actions Without a Card", action: #selector(toggleSimpleActions), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "AssemblyAI API Key…", action: #selector(showAPIKeyWindow), keyEquivalent: "")
    menu.addItem(withTitle: "Reload Settings", action: #selector(reloadSettings), keyEquivalent: "")
    menu.addItem(withTitle: "Open Input Monitoring Settings…", action: #selector(openInputMonitoring), keyEquivalent: "")
    menu.addItem(withTitle: "Quit Holler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) {
      menuItem.target = self
    }
    menu.delegate = self
    item.menu = menu
    statusItem = item
  }

  /// The mark in the menu bar, with the number of agents that need you after
  /// it when there are any, so you often needn't ask. The item widens to fit
  /// the numeral and goes back to a square without one.
  private func showNeedsYou(_ count: Int) {
    guard let statusItem else { return }
    statusItem.length = count == 0 ? NSStatusItem.squareLength : NSStatusItem.variableLength
    statusItem.button?.image = MarkView.menuBarImage(needingYou: count)
  }

  /// A typed request, for when the mic or the room misbehaves.
  @objc private func summarise() {
    guard let controller else { return showProblem() }
    controller.dismiss()
    controller.ask("What are my agents up to?")
  }

  /// A typed request, for meetings or a shared office: a follow-up if the
  /// note is open, else a new note.
  @objc private func typeQuestion() {
    guard let controller else { return showProblem() }
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = "What are my agents up to?"
    let alert = NSAlert()
    alert.messageText = "Ask Holler"
    alert.informativeText = "Type a question about your agents."
    alert.accessoryView = field
    alert.addButton(withTitle: "Ask")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    // Typing needs Holler in front; afterwards, hand the keyboard back.
    let previous = NSWorkspace.shared.frontmostApplication
    NSApp.activate()
    let response = alert.runModal()
    previous?.activate()
    let question = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard response == .alertFirstButtonReturn, !question.isEmpty else { return }
    controller.ask(question)
  }

  /// Shows the last note's exchanges again, without its cards.
  @objc private func reopenNote() {
    controller?.reopen()
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(reopenNote):
      return controller?.canReopen ?? false
    case #selector(toggleSimpleActions):
      menuItem.state = controller?.runsSimpleActionsWithoutACard == true ? .on : .off
      return controller != nil
    case #selector(toggleReadAloud):
      menuItem.state = controller?.readsAnswersAloud == true ? .on : .off
      return controller != nil
    default:
      return true
    }
  }

  @objc private func closeNote() {
    controller?.dismiss()
  }

  /// Lets a message to an idle agent go after a 3-second countdown you can
  /// cancel, instead of waiting on its card (ADR 0001). Kept across launches.
  @objc private func toggleSimpleActions() {
    guard let controller else { return showProblem() }
    controller.runsSimpleActionsWithoutACard.toggle()
    UserDefaults.standard.set(controller.runsSimpleActionsWithoutACard, forKey: Self.runsSimpleActionsKey)
  }

  private static let runsSimpleActionsKey = "RunSimpleActionsWithoutACard"

  /// Reads every answer aloud, unless you ask to just see one (ADR 0002).
  /// On until you turn it off; kept across launches.
  @objc private func toggleReadAloud() {
    guard let controller else { return showProblem() }
    controller.readsAnswersAloud.toggle()
    UserDefaults.standard.set(controller.readsAnswersAloud, forKey: Self.readsAnswersAloudKey)
  }

  private static let readsAnswersAloudKey = "ReadAnswersAloud"

  /// Forgets what you've been asking about, and closes the note if it's open.
  @objc private func newConversation() {
    controller?.newConversation()
  }

  @objc private func openInputMonitoring() {
    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    NSWorkspace.shared.open(URL(string: url)!)
  }

  /// A reload from the file says what's missing in the menu only, so saving
  /// a half-edited `.env` doesn't throw an alert in your face.
  private func fail(_ problem: SetupProblem, alert: Bool) {
    setupProblem = problem
    statusLine.title = problem.statusLine
    if alert { showProblem() }
  }

  private func showProblem() {
    switch setupProblem {
    case nil:
      return
    case .noKey:
      showAPIKeyWindow()
    case .noHerdr:
      let alert = NSAlert()
      alert.messageText = "Holler needs Herdr"
      alert.informativeText = """
        Holler talks to the coding agents running in Herdr, and couldn't find it. Install Herdr, \
        then choose Reload Settings from Holler's menu. If it's installed somewhere unusual, \
        set HERDR_PATH in \(Self.envFile?.path ?? "~/.config/holler/.env").
        """
      alert.addButton(withTitle: "Get Herdr")
      alert.addButton(withTitle: "Later")
      NSApp.activate()
      if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(URL(string: "https://herdr.dev")!)
      }
    }
  }

  /// Connects Holler to AssemblyAI, or changes the key, in a small window.
  /// A saved key is picked up at once, like a settings reload.
  @objc private func showAPIKeyWindow() {
    let window = keyWindow ?? APIKeyWindowController { [weak self] in self?.reload(from: "key window") }
    keyWindow = window
    window.show(overriddenBy: Self.keyOverride)
  }

  // MARK: - Settings

  /// The `.env` the build script recorded (the repo's), else ~/.config/holler/.env.
  static var envFile: URL? {
    envFileCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// Where a settings file may be, in order of preference. Each is watched,
  /// so one created while Holler runs is picked up when it's saved.
  static var envFileCandidates: [URL] {
    [
      Bundle.main.object(forInfoDictionaryKey: "HollerEnvFile") as? String,
      NSHomeDirectory() + "/.config/holler/.env",
    ].compactMap { $0 }.map(URL.init(fileURLWithPath:))
  }

  /// The tabs Holler started, kept so it can still close them after a restart.
  static var startedTabsFile: URL? { supportFile("started-tabs.json") }

  /// What Holler has seen the agents do: how long each has waited, and the
  /// changes since you last asked, kept so a relaunch carries on from there.
  static var herdrHistoryFile: URL? { supportFile("herdr-history.json") }

  private static func supportFile(_ name: String) -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Holler/\(name)")
  }

  /// The settings file and the environment, with the key from the Keychain
  /// when neither sets `ASSEMBLYAI_API_KEY`. The Keychain is only read then,
  /// so a key in `.env` never brings up a Keychain prompt.
  static func loadSettings() -> Settings {
    var settings = Settings.load(dotEnv: envFile)
    if settings.apiKey == nil { settings.apiKey = APIKeyStore.current }
    return settings
  }

  /// Where an `ASSEMBLYAI_API_KEY` that wins over the Keychain is set: the
  /// environment Holler was launched with, which wins over everything, or
  /// else the settings file. Nil when neither sets one.
  static var keyOverride: String? {
    func isSet(_ key: String?) -> Bool { !(key ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    if isSet(ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"]) { return "the environment Holler was launched with" }
    guard let file = envFile, let contents = try? String(contentsOf: file, encoding: .utf8),
      isSet(DotEnv.parse(contents)["ASSEMBLYAI_API_KEY"])
    else { return nil }
    return file.path
  }
}

/// What stops Holler from starting, as the menu's status line says it.
private enum SetupProblem {
  case noKey
  case noHerdr

  var statusLine: String {
    switch self {
    case .noKey: "Not ready: connect your AssemblyAI API key"
    case .noHerdr: "Not ready: Herdr isn't installed"
    }
  }
}

/// The AssemblyAI API key, shared with the speech clients so a reload's new
/// key reaches them on their next request.
final class CurrentKey: Sendable {
  private let key = Mutex("")

  var value: String {
    get { key.withLock { $0 } }
    set { key.withLock { $0 = newValue } }
  }
}

enum Sounds {
  enum Cue: String { case start, stop }

  @MainActor private static var cache: [Cue: NSSound] = [:]

  /// Plays at full volume: scripts/make-chimes.py sets the level in the file.
  @MainActor static func play(_ cue: Cue) {
    let sound =
      cache[cue]
      ?? Bundle.main.url(forResource: cue.rawValue, withExtension: "wav").flatMap {
        NSSound(contentsOf: $0, byReference: true)
      }
    guard let sound else { return }
    cache[cue] = sound
    sound.stop()
    sound.play()
  }
}
