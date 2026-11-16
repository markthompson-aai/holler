import AppKit
import BlurtEngine
import SwiftUI

/// The window where you connect Holler to your AssemblyAI account, or change
/// the key it uses. It opens on its own at launch while there's no key, and
/// from Menu bar › AssemblyAI API Key… after that.
///
/// The key is checked with AssemblyAI before it's saved, and then kept in
/// the login Keychain, through Blurt's engine (`APIKeySubmission`,
/// `APIKeyStore`), so a key that doesn't work is never stored. Nor is one
/// whose check comes back after the window was cancelled or closed.
@MainActor
final class APIKeyWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private let onConnected: () -> Void

  /// `onConnected` runs after a key has been checked and saved.
  init(onConnected: @escaping () -> Void) {
    self.onConnected = onConnected
  }

  /// Opens the window, or brings it forward if it's already open.
  /// `overriddenBy` names where an `ASSEMBLYAI_API_KEY` that wins over the
  /// Keychain is set, the settings file or the environment, if it is, so
  /// the window can say so.
  func show(overriddenBy: String?) {
    if let window {
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
      return
    }
    let window = NSWindow(
      contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let view = APIKeyView(
      display: APIKeyDisplay.resolve(key: APIKeyStore.current),
      overriddenBy: overriddenBy,
      submit: { [weak self, weak window] key in
        let checked = await APIKeyValidator().validate(key)
        // Cancelled or closed while the key was being checked: nothing is
        // saved, and nobody is left to read this answer.
        guard let self, let window, self.window === window else { return .unreachable }
        return await APIKeySubmission(keyStore: ProductionAPIKeyStore(), validate: { _ in checked }).submit(key)
      },
      openDashboard: { NSWorkspace.shared.open(APIKeyStore.dashboardURL) },
      finish: { [weak self] connected in
        self?.window?.close()
        if connected { self?.onConnected() }
      })
    window.title = "AssemblyAI API Key"
    window.contentView = NSHostingView(rootView: view)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    self.window = window
    // Holler is a menu-bar app, so it has to come forward to take typing.
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    window = nil
  }
}

/// The key window's content. Its actions are passed in, so the same view
/// renders in `--render-key-window` without the Keychain or the network.
struct APIKeyView: View {
  let display: APIKeyDisplay
  let overriddenBy: String?
  let submit: @MainActor (String) async -> APIKeySubmission.Outcome
  let openDashboard: () -> Void
  /// Called with true once a key is saved, false on Cancel.
  let finish: (Bool) -> Void

  @State private var draft = ""
  @State private var checking = false
  @State private var problem: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 14) {
        Image(nsImage: Self.icon)
          .resizable()
          .frame(width: 56, height: 56)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text(display.isConnected ? "Change Your AssemblyAI Key" : "Connect Holler to AssemblyAI")
            .font(.headline)
          Text(
            "Holler uses your AssemblyAI API key to hear what you ask, answer it with Claude through LLM Gateway, and read the answer aloud. Usage is billed to your AssemblyAI account."
          )
          .fixedSize(horizontal: false, vertical: true)
          Text("LLM Gateway isn't part of the free tier, so your account needs a card on file.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        if display.isConnected {
          LabeledContent("Current key") {
            Text(display.statusText)
              .font(display.rendersIdentifier ? .body.monospaced() : .body)
          }
          .accessibilityLabel(display.accessibilityLabel)
        }
        SecureField("API key", text: $draft, prompt: Text("Paste your API key"))
          .textFieldStyle(.roundedBorder)
          .onSubmit(connect)
          .disabled(checking)
        if let problem {
          Text(problem)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text("Your key is kept in your Mac's Keychain, and only sent to AssemblyAI.")
          .font(.callout)
          .foregroundStyle(.secondary)
        if let overriddenBy {
          Text(
            "ASSEMBLYAI_API_KEY in \(overriddenBy) takes precedence over the key saved here. Remove it there to use this one."
          )
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack {
        Button("Get an API Key", action: openDashboard)
        Spacer()
        if checking { ProgressView().controlSize(.small) }
        Button("Cancel") { finish(false) }
          .keyboardShortcut(.cancelAction)
        Button(display.isConnected ? "Update" : "Connect", action: connect)
          .keyboardShortcut(.defaultAction)
          .disabled(checking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 460)
  }

  /// Holler's icon: the bundle's in the app, the repo's when run from `.build`.
  private static var icon: NSImage {
    if Bundle.main.bundleURL.pathExtension != "app",
      let repoIcon = NSImage(contentsOfFile: "Resources/AppIcon.icns")
    {
      return repoIcon
    }
    return NSApplication.shared.applicationIconImage
  }

  private func connect() {
    let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !checking else { return }
    checking = true
    problem = nil
    Task {
      let outcome = await submit(key)
      checking = false
      if let message = Self.message(for: outcome) {
        problem = message
      } else {
        finish(true)
      }
    }
  }

  /// What to say beside the field when a key wasn't saved; nil once it was.
  static func message(for outcome: APIKeySubmission.Outcome) -> String? {
    switch outcome {
    case .valid: nil
    case .invalid: "AssemblyAI didn't accept that key. Check it in your dashboard and try again."
    case .unreachable: "Couldn't reach AssemblyAI to check the key. Check your connection and try again."
    case .saveFailed: "The key works, but Holler couldn't save it to your Keychain. Check Keychain Access and try again."
    }
  }
}

extension APIKeyView {
  /// `--render-key-window <dir>`: the window's content as it first opens and
  /// with a key already connected, light and dark, as PNGs. Drawn through
  /// AppKit so the text field and buttons look as they do on screen.
  static func renderSamples(to directory: URL) -> [URL] {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let samples: [(String, APIKeyDisplay, String?)] = [
      ("key-connect", .notConnected, nil),
      ("key-change", .resolve(key: "0123456789abcdef0123456789ab3f7c"), nil),
      ("key-overridden", .resolve(key: "0123456789abcdef0123456789ab3f7c"), "~/Projects/holler/.env"),
    ]
    var files: [URL] = []
    for (name, display, overriddenBy) in samples {
      for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let view = APIKeyView(
          display: display, overriddenBy: overriddenBy, submit: { _ in .valid }, openDashboard: {}, finish: { _ in })
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame.size = host.fittingSize
        let window = NSWindow(
          contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        let suffix = appearance == .darkAqua ? "dark" : "light"
        let file = directory.appendingPathComponent("\(name)-\(suffix).png")
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: file)) != nil
        else { continue }
        files.append(file)
      }
    }
    return files
  }
}
