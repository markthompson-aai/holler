import BlurtEngine
import CoreGraphics
import HollerCore

/// Hold-to-talk on the hotkey, from a listen-only `CGEventTap`. Adapted from
/// Blurt's `DictationKeyTap`; the decisions (edge dedup, combo detection)
/// are Blurt's engine `DictationKeyRouter`, with one key and hold mode. A
/// different key takes a new tap; `stop()` the old one first.
///
/// Listen-only means it swallows nothing: ⌥ still types ⌥-characters, and a
/// combo like ⌥3 reaches the focused app while the press is reported as a
/// cancel. For the same reason it never acts on Esc: the key would reach the
/// focused app too, where it interrupts a working agent. Esc closes the note
/// only through Holler's own panel, while that holds the keyboard
/// (`ReturnKeyPanel`). It needs the Input Monitoring permission.
@MainActor
final class HotkeyTap {
  let key: Settings.Hotkey
  private let onPress: @MainActor () -> Void
  private let onRelease: @MainActor () -> Void
  private let onCancel: @MainActor () -> Void
  private var router: DictationKeyRouter
  private let triggerFlag: CGEventFlags
  private let reference = ContinuousClock.now
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?

  init(
    key: Settings.Hotkey,
    onPress: @escaping @MainActor () -> Void,
    onRelease: @escaping @MainActor () -> Void,
    onCancel: @escaping @MainActor () -> Void
  ) {
    self.key = key
    let trigger = key.triggerKey
    router = DictationKeyRouter(triggerKeyCode: trigger.keyCode, activation: .hold)
    triggerFlag = CGEventFlags(rawValue: trigger.deviceModifierMask)
    self.onPress = onPress
    self.onRelease = onRelease
    self.onCancel = onCancel
  }

  var isInstalled: Bool { tap != nil }

  /// Removes the tap, so nothing reaches this object again. A press in
  /// progress is reported as a cancel.
  func stop() {
    guard let tap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    CFMachPortInvalidate(tap)
    self.tap = nil
    source = nil
    if router.reset() { onCancel() }
  }

  /// Installs the tap if it isn't already. Fails until Input Monitoring is
  /// granted, so the caller retries.
  @discardableResult
  func ensureRunning() -> Bool {
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: true)
      return true
    }
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    guard
      let created = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(mask),
        callback: hotkeyTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else { return false }
    tap = created
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: created, enable: true)
    return true
  }

  fileprivate func handle(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      // The system turned the tap off; events in between may be lost, so only
      // trust a held state if the key is still physically down.
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      let stillHeld = CGEventSource.flagsState(.combinedSessionState).contains(triggerFlag)
      if router.recoverFromDroppedEvents(triggerStillHeld: stillHeld) { onCancel() }
      return
    }
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let routed: DictationKeyRouter.Event
    switch type {
    case .flagsChanged: routed = .flagsChanged(keyCode: keyCode, triggerFlagIsOn: event.flags.contains(triggerFlag))
    case .keyDown: routed = .keyDown(keyCode: keyCode)
    default: return
    }
    switch router.handle(routed, at: reference.duration(to: .now)) {
    case .start: onPress()
    case .stop: onRelease()
    case .cancel: onCancel()
    case .latch, .none: break
    }
  }
}

extension Settings.Hotkey {
  /// The key in Blurt's terms, which the tap listens for.
  var triggerKey: TriggerKey {
    switch self {
    case .rightOption: .rightOption
    case .rightCommand: .rightCommand
    case .function: .function
    }
  }
}

private func hotkeyTapCallback(
  _: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<HotkeyTap>.fromOpaque(userInfo).takeUnretainedValue()
  nonisolated(unsafe) let event = event
  // The tap's run loop source is on the main run loop.
  MainActor.assumeIsolated { tap.handle(type: type, event: event) }
  return Unmanaged.passUnretained(event)
}
