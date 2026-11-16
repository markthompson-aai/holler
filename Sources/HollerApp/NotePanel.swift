import AppKit
import SwiftUI
import HollerCore

/// A borderless floating panel that never activates the app, so the terminal
/// you were typing in keeps focus. It can still become key for a click on Send.
final class NotePanel: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: NoteStyle.width, height: 80),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true)
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    backgroundColor = .clear
    isOpaque = false
    // The note draws its own shadow. It follows the system's light or dark
    // appearance, live, by inheriting the app's.
    hasShadow = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
  }

  /// Esc closes the note through `ReturnKeyPanel`, while that has the
  /// keyboard; don't beep for it here.
  override func cancelOperation(_ sender: Any?) {}

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// An invisible panel that holds the keyboard while a confirm card is
/// waiting or counting down, so Return confirms it and reaches nothing else,
/// and Esc closes the note, dropping the card. Any other key asks for the
/// keyboard to go back to your app; that key itself is lost, since Holler
/// can't pass it on. Esc only works here, where the key comes to Holler
/// alone: anywhere else it would reach the app in front as well, and
/// interrupt the agent you're looking at.
///
/// It's separate from the note because the only way to give the keyboard
/// back is to take the window off screen, which made the note flicker. Like
/// the note, it never activates the app, so the terminal you were in stays
/// in front.
final class ReturnKeyPanel: NSPanel {
  /// Return or keypad Enter.
  var onReturn: () -> Void = {}
  /// Esc: close the note.
  var onEscape: () -> Void = {}
  /// Any other key, including Return with a modifier.
  var onOtherKey: () -> Void = {}
  private static let returnKeyCodes: Set<UInt16> = [36, 76]
  private static let escapeKeyCode: UInt16 = 53

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true)
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
  }

  /// Esc, if AppKit hands it over as a cancel rather than a key press.
  override func cancelOperation(_ sender: Any?) { onEscape() }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == Self.escapeKeyCode { return onEscape() }
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard Self.returnKeyCodes.contains(event.keyCode), modifiers.isEmpty else { return onOtherKey() }
    // A held Return confirms one card, not each card in turn.
    if !event.isARepeat { onReturn() }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Takes the first click, so Send works without first focusing the panel.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows and hides the note as the controller's state changes, sized to its
/// content and pinned to the top-right of the screen you're working on.
@MainActor
final class NotePanelController {
  /// A press shorter than this never shows the note. It matches the
  /// controller's tap threshold, so taps and quick ⌥-shortcuts don't flash it.
  private static let showDelay: Duration = .milliseconds(300)

  private let controller: AssistantController
  let panel = NotePanel()
  private let returnKey = ReturnKeyPanel()
  private let room = NoteRoom()
  private var screen: NSScreen?
  private var contentSize = CGSize(width: NoteStyle.width, height: 80)
  private var pendingShow: Task<Void, Never>?
  /// A smaller size waits for the note to finish animating, so the panel doesn't clip it.
  private var pendingShrink: Task<Void, Never>?

  init(controller: AssistantController, level: LevelModel) {
    self.controller = controller
    let root = NoteView(controller: controller, level: level, room: room) { [weak self] size in
      self?.resize(to: size)
    }
    let hosting = FirstClickHostingView(rootView: root)
    hosting.sizingOptions = []
    panel.contentView = hosting
    returnKey.onReturn = { controller.confirmNewest() }
    returnKey.onEscape = { controller.dismiss() }
    returnKey.onOtherKey = { controller.handBackKeyboard() }
    observe()
  }

  private func observe() {
    withObservationTracking {
      _ = controller.phase
      _ = controller.holdsKeyboard
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.update()
        self?.observe()
      }
    }
  }

  private func update() {
    guard controller.isVisible else {
      pendingShow?.cancel()
      pendingShow = nil
      pendingShrink?.cancel()
      pendingShrink = nil
      panel.orderOut(nil)
      returnKey.orderOut(nil)
      screen = nil
      return
    }
    if panel.isVisible { return updateKeyboard() }
    guard pendingShow == nil else { return }
    if controller.phase == .listening {
      pendingShow = Task {
        try? await Task.sleep(for: Self.showDelay)
        guard !Task.isCancelled else { return }
        pendingShow = nil
        if controller.isVisible { show() }
      }
    } else {
      show()
    }
  }

  private func show() {
    screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    if let height = screen?.visibleFrame.height { room.screenHeight = height }
    layout(contentSize)
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    updateKeyboard()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      panel.animator().alphaValue = 1
    }
  }

  /// Holler has the keyboard while a confirm card is waiting, so Return
  /// confirms it, and gives it back to the app you were in once none is, or
  /// once you press another key.
  private func updateKeyboard() {
    if controller.holdsKeyboard {
      guard !returnKey.isKeyWindow else { return }
      // On the note's screen, top-right, under the note's margin.
      if let frame = panel.screen?.visibleFrame {
        returnKey.setFrameOrigin(NSPoint(x: frame.maxX - 1, y: frame.maxY - 1))
      }
      returnKey.orderFrontRegardless()
      returnKey.makeKey()
    } else {
      returnKey.orderOut(nil)
    }
  }

  private func resize(to size: CGSize) {
    contentSize = size
    pendingShrink?.cancel()
    pendingShrink = nil
    let current = panel.frame.size
    guard panel.isVisible, size.width < current.width || size.height < current.height else {
      return layout(size)
    }
    layout(CGSize(width: max(size.width, current.width), height: max(size.height, current.height)))
    pendingShrink = Task {
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      layout(contentSize)
    }
  }

  /// Flush with the visible screen's top-right corner: the note's margins hold
  /// its inset and its shadow.
  private func layout(_ size: CGSize) {
    guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
    let height = min(size.height, visible.height)
    panel.setFrame(
      NSRect(x: visible.maxX - size.width, y: visible.maxY - height, width: size.width, height: height),
      display: true)
  }
}
