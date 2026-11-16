import AVFoundation
import CoreGraphics
import Foundation
import HollerCore

/// `Holler --check`: the launch-time setup, without the UI.
@MainActor
enum SetupCheck {
  static func run() -> Bool {
    var ok = true
    func report(_ passed: Bool, _ line: String) {
      print("\(passed ? "✓" : "✗") \(line)")
      ok = ok && passed
    }

    let envFile = AppDelegate.envFile
    print("  settings file: \(envFile?.path ?? "none (optional)")")
    let settings = AppDelegate.loadSettings()
    let keySource =
      settings.apiKey == nil
      ? "missing: open Holler to connect one"
      : AppDelegate.keyOverride.map { "from \($0)" } ?? "from the Keychain"
    report(settings.apiKey != nil, "AssemblyAI API key \(keySource)")
    print("  model: \(settings.model)")
    report(settings.effortProblem == nil, "effort: \(settings.effortProblem ?? settings.effort ?? "the model's own")")
    report(settings.hotkeyProblem == nil, "hotkey: \(settings.hotkeyProblem ?? settings.hotkey.label)")
    if !settings.filter.workspaces.isEmpty {
      print("  only workspaces: \(settings.filter.workspaces.joined(separator: ", "))")
    }
    // As Holler compares them, so a folder that isn't hidden shows here.
    for folder in settings.filter.excludedPathPrefixes { print("  hidden folder: \(folder)") }
    for problem in settings.excludeProblems { report(false, problem) }

    if let herdrPath = settings.herdrPath {
      let herdr = HerdrClient(executable: herdrPath, filter: settings.filter)
      let semaphore = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var result: Result<[HerdrAgent], any Error> = .success([])
      Task.detached {
        do { result = .success(try await herdr.agents()) } catch { result = .failure(error) }
        semaphore.signal()
      }
      semaphore.wait()
      switch result {
      case .success(let agents): report(true, "herdr at \(herdrPath.path): \(agents.count) agents visible")
      case .failure(let error): report(false, "herdr at \(herdrPath.path): \(error)")
      }
    } else {
      report(false, "herdr not found: install it from https://herdr.dev, or set HERDR_PATH")
    }

    // Informational: these belong to whichever app launched this process.
    print("  microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).label)")
    print("  input monitoring permission: \(CGPreflightListenEventAccess() ? "granted" : "not granted")")
    return ok
  }
}

extension AVAuthorizationStatus {
  fileprivate var label: String {
    switch self {
    case .authorized: "granted"
    case .denied: "denied"
    case .restricted: "restricted"
    case .notDetermined: "not asked yet"
    @unknown default: "unknown"
    }
  }
}
