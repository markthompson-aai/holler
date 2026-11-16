import AppKit
import HollerCore
import HollerSpeech

/// `Holler --snapshot "<question>" <out.png>`: asks a typed question
/// through the real note panel (live Herdr and LLM Gateway, no mic or hotkey,
/// so no permission prompts), saves the panel's pixels and exits.
@MainActor
enum SnapshotRun {
  private static var retained: [AnyObject] = []

  static func start(question: String, output: URL) {
    let settings = AppDelegate.loadSettings()
    guard let herdrPath = settings.herdrPath, let apiKey = settings.apiKey else {
      print("not set up; run --check")
      exit(1)
    }
    let herdr = HerdrClient(executable: herdrPath, filter: settings.filter)
    let gateway = LLMGateway(apiKey: apiKey)
    let model = settings.model
    let effort = settings.effort
    let controller = AssistantController(voice: BlurtVoiceInput(speech: SpeechInput(apiKey: apiKey)), herdr: herdr) {
      AssistantSession(gateway: gateway, herdr: herdr, configuration: .init(model: model, effort: effort))
    }
    let notePanel = NotePanelController(controller: controller, level: LevelModel())
    retained = [controller, notePanel]

    let clock = ContinuousClock()
    let start = clock.now
    controller.ask(question)
    Task {
      while controller.phase == .thinking || controller.phase == .idle {
        try? await Task.sleep(for: .milliseconds(100))
        if clock.now - start > .seconds(90) { break }
      }
      // Let the panel settle on its final size before capturing.
      try? await Task.sleep(for: .milliseconds(500))
      print("phase: \(controller.phase) after \(clock.now - start)")
      print("panel frame: \(notePanel.panel.frame)")
      if let view = notePanel.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: output)
        print("saved \(output.path)")
      }
      exit(controller.isFailed ? 1 : 0)
    }
  }
}
