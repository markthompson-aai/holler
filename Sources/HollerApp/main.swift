import AppKit
import HollerSpeech
import OSLog

let arguments = CommandLine.arguments
Fonts.register()
// Before anything else touches Blurt's engine: its loggers, defaults and
// Keychain lookups resolve their identity once.
SpeechInput.configureEngine()

// `--render-key-window <dir>` draws the API key window's states to PNGs and exits.
if let flag = arguments.firstIndex(of: "--render-key-window") {
  let directory = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "previews"
  let files = MainActor.assumeIsolated {
    _ = NSApplication.shared
    return APIKeyView.renderSamples(to: URL(fileURLWithPath: directory))
  }
  for file in files { print(file.path) }
  exit(files.isEmpty ? 1 : 0)
}

// `--render-previews <dir>` draws the note in each state to PNGs and exits,
// 1 if any state failed to render. No windows, permissions or network, so it
// runs anywhere (including CI).
if let flag = arguments.firstIndex(of: "--render-previews") {
  let directory = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "previews"
  let complete = MainActor.assumeIsolated {
    let files = PreviewRenderer.renderAll(to: URL(fileURLWithPath: directory))
    for file in files { print(file.path) }
    return files.count == PreviewRenderer.renderCount
  }
  exit(complete ? 0 : 1)
}

// `--check-previews [goldens-dir] [output-dir]` renders every state afresh,
// compares each with its golden image and exits 1 on a change, leaving the
// fresh renders and a difference image per change in the output directory.
if let flag = arguments.firstIndex(of: "--check-previews") {
  let goldens = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "Tests/Goldens/note"
  let output = arguments.indices.contains(flag + 2) ? arguments[flag + 2] : "previews/check"
  let passed = MainActor.assumeIsolated {
    GoldenCheck.run(goldens: URL(fileURLWithPath: goldens), output: URL(fileURLWithPath: output))
  }
  exit(passed ? 0 : 1)
}

// `--show-note <state> [light|dark]` shows one preview state in the real,
// live panel (with a backdrop window behind it).
if let flag = arguments.firstIndex(of: "--show-note"), arguments.indices.contains(flag + 1) {
  let backdrop = arguments.indices.contains(flag + 2) ? arguments[flag + 2] : nil
  MainActor.assumeIsolated { PreviewRenderer.showLive(state: arguments[flag + 1], backdrop: backdrop) }
}

// `--check` reports whether the app is set up (API key, Herdr) and exits,
// without opening windows or asking for permissions.
if arguments.contains("--check") {
  let ok = MainActor.assumeIsolated { SetupCheck.run() }
  exit(ok ? 0 : 1)
}

if let flag = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(flag + 2) {
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    SnapshotRun.start(question: arguments[flag + 1], output: URL(fileURLWithPath: arguments[flag + 2]))
    app.run()
  }
}

MainActor.assumeIsolated {
  // One Holler at a time. A second copy, say build/Holler.app beside the one
  // in /Applications, would listen for the same hotkey and answer every
  // press twice, and both would write the tabs Holler started.
  let own = ProcessInfo.processInfo.processIdentifier
  if let bundle = Bundle.main.bundleIdentifier,
    NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
      .contains(where: { $0.processIdentifier != own && !$0.isTerminated })
  {
    Logger(subsystem: "com.assemblyai.holler", category: "Settings")
      .notice("Holler is already running, so this copy is quitting")
    exit(0)
  }
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  // NSApplication holds its delegate weakly.
  withExtendedLifetime(delegate) { app.run() }
}
