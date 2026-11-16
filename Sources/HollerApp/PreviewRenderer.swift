import AppKit
import SwiftUI
import HollerCore

/// Renders the pill and note in each state to PNGs, in the light and dark
/// appearances, with sample data. The way to check the UI without granting
/// permissions or speaking. The mark is drawn at one fixed moment, whatever
/// the Reduce Motion setting, so a state renders the same every time and the
/// golden-image check (`GoldenCheck`) can compare it.
@MainActor
enum PreviewRenderer {
  private struct SilentVoice: VoiceInput {
    func start(keyTerms: [String]) async throws {}
    func finish() async throws -> String { "" }
    func cancel() async {}
  }

  /// How many files a full render writes: each state in light and dark.
  static var renderCount: Int { states.count * 2 }

  /// The files written, one per state and appearance, named
  /// `<state>-<light|dark>.png`. Fewer than `renderCount` means a state
  /// failed to render, which is said on stderr.
  static func renderAll(to directory: URL) -> [URL] {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var files: [URL] = []
    for (name, phase, exchanges, notice) in states {
      let micLive = name != "0-connecting"
      for scheme in [ColorScheme.light, .dark] {
        let controller = previewController()
        controller.showPreview(
          phase: phase, exchanges: exchanges, notice: notice, micLive: micLive, agentList: agentList(for: name))
        let level = LevelModel()
        level.level = 0.6
        let view = NoteView(controller: controller, level: level)
          .padding(24)
          .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.9))
          .environment(\.colorScheme, scheme)
          .environment(\.markFrozenAt, Date(timeIntervalSinceReferenceDate: 0))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let file = directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
        guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
          (try? data.write(to: file)) != nil
        else {
          FileHandle.standardError.write(Data("could not render \(file.lastPathComponent)\n".utf8))
          continue
        }
        files.append(file)
      }
    }
    return files
  }

  private static var retained: [AnyObject] = []

  /// Shows one state in the real panel, live on screen, so it can be judged
  /// without speaking. `backdrop` puts a light or dark window behind it.
  static func showLive(state: String, backdrop: String?) {
    guard let (name, phase, exchanges, notice) = states.first(where: { $0.0.contains(state) }) else {
      print("no state matching \(state); try one of: \(states.map(\.0).joined(separator: ", "))")
      exit(1)
    }
    let app = startApp(backdrop: backdrop)
    let level = LevelModel()
    level.level = 0.6
    let controller = previewController()
    let notePanel = NotePanelController(controller: controller, level: level)
    retained += [controller, notePanel]
    controller.showPreview(
      phase: phase, exchanges: exchanges, notice: notice, micLive: name != "0-connecting", agentList: agentList(for: name))
    print("showing \(name); Ctrl-C to quit")
    app.run()
  }

  private static func startApp(backdrop: String?) -> NSApplication {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if let backdrop, let screen = NSScreen.main {
      let frame = screen.visibleFrame
      let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.backgroundColor = backdrop == "dark" ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.97, alpha: 1)
      window.orderFrontRegardless()
      retained.append(window)
    }
    return app
  }

  private static func previewController() -> AssistantController {
    AssistantController(voice: SilentVoice(), herdr: HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"))) {
      fatalError("previews never ask")
    }
  }

  private static let search = HerdrAgent(
    paneId: "w6:p3", kind: "claude", status: "idle", workspace: "demo", tab: "search",
    cwd: "/Users/demo/Projects/search", title: "Language fallback", focused: false)

  private static let summary = """
    **1 needs you, 2 working, 2 idle.** The api agent needs a decision from you.

    - **demo / api**: needs you. Asks whether to drop the legacy `/v1` routes.
    - **demo / search**: idle. Language fallback is done and all 214 tests pass.
    - **demo / web**: working. Rebuilding the settings page; about half the components are done.
    - **demo / docs**: working. Writing the migration guide.
    - **demo / infra**: idle. The staging deploy succeeded.
    """

  private static let request = "What are my agents up to?"
  private static let followUp = "Ask the search agent to continue with the next steps"
  private static let queued = "Ready to send. Confirm below and I'll pass it to **demo / search**."
  private static let message = "Continue with the next steps: open a PR for the language fallback and request review."
  private static let correction = "Actually, tell it to open the PR as a draft"
  private static let corrected = "Open the PR for the language fallback as a draft, and request review."
  private static let startRequest = "Start a new agent in the web project to add a dark mode toggle"
  private static let startQueued = "Ready to start. Confirm below and I'll open a new **demo** tab for it."
  private static let newAgent = NewAgent(
    workspace: HerdrWorkspace(id: "w6", label: "demo", tabs: ["web", "api"], folders: ["/Users/demo/holler-demo/web"]),
    folder: "/Users/demo/holler-demo/web", tab: "dark-mode",
    task: "Add a dark mode toggle to the settings page, following the existing theme tokens.")
  private static let worktreeRequest = "Start Claude in a worktree of the web project to try the cache fix"
  private static let worktreeQueued = "Ready to start. Confirm below and I'll make a new worktree, **cache-fix**, for it."
  private static let worktreeAgent = NewAgent(
    workspace: newAgent.workspace, folder: "/Users/demo/holler-demo/web", tab: "cache-fix",
    task: "Try caching the settings lookup and see whether the page loads faster.",
    worktree: NewWorktree(repository: "web", branch: "cache-fix", path: "/Users/demo/.herdr/worktrees/web/cache-fix"))

  private static let closeRequest = "Close the dark-mode tab"
  private static let closeQueued = "Ready to close. Confirm below and I'll close **demo / dark-mode**."
  private static let darkMode = TabToClose(
    tabId: "w6:t7", workspace: "demo", tab: "dark-mode",
    agents: [
      .init(
        agent: HerdrAgent(
          paneId: "w6:p9", kind: "claude", status: "working", workspace: "demo", tab: "dark-mode", tabId: "w6:t7",
          cwd: "/Users/demo/holler-demo/web", title: "Dark mode toggle", focused: false),
        lastLine: "Updating ThemeToggle.tsx to read the saved preference on load.")
    ])

  private static let interruptRequest = "Stop the web agent"
  private static let interrupt = AgentToInterrupt(
    agent: HerdrAgent(
      paneId: "w6:p2", kind: "claude", status: "working", workspace: "demo", tab: "web", tabId: "w6:t2",
      cwd: "/Users/demo/holler-demo/web", title: "Settings page", focused: false),
    lastLine: "Moving every settings section into its own component.")

  /// The agent list the moment the key is released, for the state that shows it.
  private static func agentList(for state: String) -> [AgentRow]? {
    guard state.contains("agent-list") else { return nil }
    return [
      AgentRow(name: "demo / api", state: .needsYou, update: "Waiting 12 min."),
      AgentRow(name: "demo / search", state: .working, update: "Working for 3 min."),
      AgentRow(name: "demo / web", state: .working, update: ""),
      AgentRow(name: "demo / docs", state: .idle, update: "Stopped at least 25 min ago."),
      AgentRow(name: "acme / tests", state: .idle, update: ""),
    ]
  }

  private static var states:
    [(String, AssistantController.Phase, [AssistantController.Exchange], String?)]
  {
    let answered = AssistantController.Exchange(id: 1, request: request, answer: summary)
    func action(_ status: ActionStatus) -> AssistantController.Exchange {
      AssistantController.Exchange(
        id: 2, request: followUp, answer: queued,
        actions: [.init(id: "a1", content: SendAction(agent: search, text: message).card, status: status)])
    }
    let countingDown = AssistantController.Exchange(
      id: 2, request: followUp, answer: "Sending to **demo / search**.",
      actions: [.init(id: "a1", content: SendAction(agent: search, text: message).card, status: .countingDown(3))])
    var paused = countingDown
    paused.actions[0].status = .paused
    let startCountingDown = AssistantController.Exchange(
      id: 2, request: startRequest, answer: "Starting Claude in **demo / dark-mode**.",
      actions: [.init(id: "a2", content: StartAction(newAgent).card, status: .countingDown(2))])
    let waitsWhy = AssistantController.Exchange(
      id: 2, request: followUp, answer: queued,
      actions: [
        .init(
          id: "a1", content: SendAction(agent: search, text: message).card,
          status: .waiting(because: "search is working, so this waits for you."))
      ])
    let correcting = AssistantController.Exchange(
      id: 3, request: correction,
      actions: [.init(id: "a2", content: SendAction(agent: search, text: corrected).card)])
    let start = AssistantController.Exchange(
      id: 2, request: startRequest, answer: startQueued,
      actions: [.init(id: "a2", content: StartAction(newAgent).card)])
    let worktree = AssistantController.Exchange(
      id: 2, request: worktreeRequest, answer: worktreeQueued,
      actions: [.init(id: "a5", content: StartAction(worktreeAgent).card)])
    let close = AssistantController.Exchange(
      id: 2, request: closeRequest, answer: closeQueued,
      actions: [.init(id: "a3", content: CloseAction(darkMode).card)])
    let interrupting = AssistantController.Exchange(
      id: 2, request: interruptRequest, actions: [.init(id: "a4", content: InterruptAction(interrupt).card)])
    return [
      ("0-connecting", .listening, [], nil),
      ("1-listening", .listening, [], nil),
      ("2-thinking", .thinking, [.init(id: 1, request: request, activity: "Reviewing 5 agents…")], nil),
      ("2b-agent-list", .transcribing, [], nil),
      ("2c-agent-list-thinking", .thinking, [.init(id: 1, request: request, activity: "Reviewing 5 agents…")], nil),
      ("3-summary", .ready, [answered], nil),
      ("4-confirm", .ready, [answered, action(.waiting(because: nil))], nil),
      ("4b-correction", .ready, [action(.replaced), correcting], nil),
      ("4c-countdown", .ready, [answered, countingDown], nil),
      ("4d-countdown-start", .ready, [answered, startCountingDown], nil),
      ("4e-waits-why", .ready, [answered, waitsWhy], nil),
      ("4f-countdown-paused", .listening, [answered, paused], nil),
      ("5-sent", .ready, [action(.done)], nil),
      ("5b-start", .ready, [answered, start], nil),
      ("5b-start-worktree", .ready, [answered, worktree], nil),
      ("5c-close", .ready, [answered, close], nil),
      ("5d-interrupt", .ready, [answered, interrupting], nil),
      ("6-follow-up-listening", .listening, [answered], nil),
      ("7-error", .failed("LLM Gateway returned 429: rate limited"), [.init(id: 1, request: request)], nil),
      (
        "8-reopened", .ready,
        [answered, .init(id: 2, request: followUp, answer: "Ready to send to demo / search.", cardsLeftOut: 1)], nil
      ),
      ("8b-reopened-ended", .ready, [], "That conversation has ended, so there's nothing to reopen."),
    ]
  }
}
