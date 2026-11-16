import AppKit
import HollerCore

/// What the note shows, as far as VoiceOver needs to know, taken from the
/// controller at one moment so two moments can be compared.
struct NoteSnapshot: Equatable {
  var phase: AssistantController.Phase
  var isMicLive: Bool
  var notice: String?
  var exchanges: [AssistantController.Exchange]
  /// Whether Return confirms the newest waiting card.
  var holdsKeyboard: Bool
  /// The key you hold to follow up.
  var hotkey: Settings.Hotkey

  @MainActor init(_ controller: AssistantController) {
    phase = controller.phase
    isMicLive = controller.isMicLive
    notice = controller.notice
    exchanges = controller.exchanges
    holdsKeyboard = controller.holdsKeyboard
    hotkey = controller.hotkey
  }

  init(
    phase: AssistantController.Phase, isMicLive: Bool, notice: String?, exchanges: [AssistantController.Exchange],
    holdsKeyboard: Bool = false, hotkey: Settings.Hotkey = .default
  ) {
    self.phase = phase
    self.isMicLive = isMicLive
    self.notice = notice
    self.exchanges = exchanges
    self.holdsKeyboard = holdsKeyboard
    self.hotkey = hotkey
  }

  /// One line on the note as a whole, for its accessibility value: what Holler
  /// is doing, or what's waiting for you.
  var value: String {
    switch phase {
    case .idle: return ""
    case .listening: return isMicLive ? "Listening" : "Connecting"
    case .transcribing: return "Transcribing"
    case .thinking: return "Thinking"
    case .failed(let message): return "Request failed: \(message)"
    case .ready:
      if waitingCards.isEmpty {
        return exchanges.last?.answer == nil ? "Ready" : "Answer shown. Hold \(hotkey.spokenName) to follow up"
      }
      if waitingCards.contains(where: { $0.status.isCountingDown }) {
        return holdsKeyboard
          ? "A card is counting down. Return to run it now, Escape to cancel"
          : "A card is counting down. Cancel in the note, or tap \(hotkey.spokenName) to close it"
      }
      return holdsKeyboard ? "A confirm card is waiting. Return to confirm" : "A confirm card is waiting"
    }
  }

  /// The cards still waiting for you, or counting down.
  var waitingCards: [AssistantController.Card] {
    exchanges.flatMap(\.actions).filter { $0.status.isUndecided }
  }

  /// Whether a countdown is paused for your follow-up.
  var hasPausedCard: Bool {
    exchanges.contains { $0.actions.contains { $0.status == .paused } }
  }
}

/// A line for VoiceOver to read when the note changes. The note never takes
/// focus (the terminal you were in keeps it), so VoiceOver can't find its way
/// to the note on its own; these are posted instead.
struct NoteAnnouncement: Equatable {
  enum Priority: Equatable { case medium, high }

  var text: String
  var priority: Priority = .medium

  /// What changed between two moments, worth saying. Nothing while the note
  /// is closed; nothing for an answer Holler is reading aloud itself.
  static func changes(from old: NoteSnapshot, to new: NoteSnapshot) -> [NoteAnnouncement] {
    guard new.phase != .idle else { return [] }
    var lines: [NoteAnnouncement] = []

    // A closed note shown again, with its answers already in: one line, not
    // every answer over again. A new request from a closed note thinks first,
    // and an alert opening the note is announced as the answer it is.
    if old.phase == .idle, new.phase == .ready, let last = new.exchanges.last, let answer = last.answer, !last.fromAlert {
      return [.init(text: "Reopened the last note. \(answerLine(answer))")]
    }

    // The phase.
    let listening = new.phase == .listening && new.isMicLive
    let wasListening = old.phase == .listening && old.isMicLive
    if listening, !wasListening {
      lines.append(.init(text: "Listening"))
    } else if new.phase == .thinking, old.phase != .thinking {
      lines.append(.init(text: "Thinking"))
    }
    if case .failed(let message) = new.phase, new.phase != old.phase {
      lines.append(.init(text: "Request failed: \(message)", priority: .high))
    }

    // A notice, such as "Didn't catch that".
    if let notice = new.notice, notice != old.notice {
      lines.append(.init(text: notice))
    }

    // Holding the key pauses every countdown: one line for the first card to
    // pause, not one a card.
    if !old.hasPausedCard, new.hasPausedCard {
      lines.append(.init(text: "Countdown paused."))
    }

    // Answers, then cards, in the order they appear. An answer that comes
    // with a card ("Ready to send. Confirm below…") is left to the card.
    for exchange in new.exchanges {
      let before = old.exchanges.first { $0.id == exchange.id }
      let newCards = exchange.actions.filter { card in !(before?.actions.contains { $0.id == card.id } ?? false) }
      let hasNewWaitingCard = newCards.contains { $0.status.isUndecided }
      if let answer = exchange.answer, before?.answer == nil, !exchange.readAloud, !hasNewWaitingCard {
        lines.append(.init(text: answerLine(answer)))
      }
      for card in exchange.actions {
        guard let was = before?.actions.first(where: { $0.id == card.id }) else {
          switch card.status {
          case .waiting(let reason):
            lines.append(
              .init(text: cardLine(card.content, waitsBecause: reason, returnConfirms: new.holdsKeyboard), priority: .high))
          case .countingDown(let seconds):
            lines.append(
              .init(text: countdownLine(card.content, seconds: seconds, returnRuns: new.holdsKeyboard), priority: .high))
          default:
            break
          }
          continue
        }
        // A replaced card says nothing: the card that replaces it does. Nor
        // does a countdown's tick; what it ends in does.
        guard card.status != was.status, card.status != .replaced else { continue }
        if case .waiting(let reason) = card.status, was.status.isCountingDown {
          // "Its countdown ended. api started working, so this waits for you. Send to …"
          let ended = reason.map { sentence("Its countdown ended.", $0) } ?? "Its countdown ended, but it waits for you instead"
          lines.append(.init(text: sentence(ended, cardLine(card.content, returnConfirms: new.holdsKeyboard)), priority: .high))
        } else if let line = statusLine(card.content, card.status) {
          lines.append(.init(text: line, priority: .high))
        }
      }
    }
    return lines
  }

  /// A summary as its count and first sentence; anything else as its first
  /// line or two, with the Markdown taken out.
  static func answerLine(_ markdown: String) -> String {
    switch NoteAnswer.parse(markdown) {
    case .summary(let headline, let subline, _):
      return sentence(headline + ".", subline.map(firstSentence))
    case .blocks(let blocks):
      let texts = blocks.map(\.text)
      guard let first = texts.first else { return "" }
      if case .heading = blocks[0], texts.count > 1 {
        return sentence(plain(first), firstSentence(texts[1]))
      }
      return firstSentence(first)
    }
  }

  /// "Send to demo / search: Continue with the next steps. Return to
  /// confirm.", with why it waits rather than counting down, if it says:
  /// "… next steps. search is working, so this waits for you. Return to confirm."
  static func cardLine(_ card: ConfirmCard, waitsBecause reason: String? = nil, returnConfirms: Bool = true) -> String {
    sentence(
      sentence(describe(card), reason), returnConfirms ? "Return to confirm." : "\(card.words.button) or Cancel in the note.")
  }

  /// "Send to demo / search: Continue with the next steps. Sending in 3
  /// seconds. Return to send now, Escape to cancel."
  static func countdownLine(_ card: ConfirmCard, seconds: Int, returnRuns: Bool = true) -> String {
    countingLine(card, "\(card.words.countdown) \(seconds) second\(seconds == 1 ? "" : "s").", returnRuns: returnRuns)
  }

  /// A paused card's status line, true for the whole pause: while you speak,
  /// and while Holler transcribes and answers.
  static let paused = "Paused for your follow-up"

  /// "Send to demo / search: Continue with the next steps. Paused for your
  /// follow-up. Return to send now, Escape to cancel."
  static func pausedLine(_ card: ConfirmCard, returnRuns: Bool = true) -> String {
    countingLine(card, paused + ".", returnRuns: returnRuns)
  }

  private static func countingLine(_ card: ConfirmCard, _ status: String, returnRuns: Bool) -> String {
    sentence(
      sentence(describe(card), status),
      returnRuns
        ? "Return to \(card.words.runNow.lowercased()), Escape to cancel." : "\(card.words.runNow) or Cancel in the note.")
  }

  /// "Send to demo / search: Continue with the next steps." with any
  /// placeholder and warnings the card shows.
  private static func describe(_ card: ConfirmCard) -> String {
    var line = "\(card.verb) \(card.target)"
    if let body = card.body {
      line += ": " + firstSentence(body)
    } else if let placeholder = card.placeholder {
      line = sentence(line, placeholder)
    }
    for warning in card.warnings { line = sentence(line, warning) }
    return line
  }

  /// The card's own words for where its action got to; nothing for the
  /// moment between confirming and done, for a countdown's tick, or for a
  /// card another replaced.
  static func statusLine(_ card: ConfirmCard, _ status: ActionStatus) -> String? {
    switch status {
    case .waiting, .countingDown, .paused, .busy, .replaced: nil
    case .done: "\(card.words.done): \(card.target)"
    case .cancelled, .withdrawn: card.words.cancelled
    case .failed(let message): "\(card.words.failed): \(message)"
    }
  }

  /// Up to the first full stop, question mark or exclamation mark that ends a
  /// sentence, Markdown taken out. A full stop inside a word ("v1.2", "api.ts") doesn't count.
  static func firstSentence(_ text: String) -> String {
    let text = plain(text)
    var end = text.startIndex
    while end < text.endIndex {
      let next = text.index(after: end)
      if ".?!".contains(text[end]), next == text.endIndex || text[next].isWhitespace {
        return String(text[...end])
      }
      end = next
    }
    return text
  }

  /// Inline Markdown emphasis and code marks taken out, so VoiceOver doesn't
  /// read "star star".
  static func plain(_ text: String) -> String {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    guard let attributed = try? AttributedString(markdown: text, options: options) else { return text }
    return String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Joins two lines as sentences; the second may be missing.
  private static func sentence(_ first: String, _ second: String?) -> String {
    guard let second, !second.isEmpty else { return first }
    let ended = first.last.map { ".?!".contains($0) } ?? true
    return (ended ? first : first + ".") + " " + second
  }
}

extension NoteBlock {
  var text: String {
    switch self {
    case .paragraph(let text), .bullet(let text), .subBullet(let text), .heading(let text): text
    }
  }
}

/// Posts a VoiceOver announcement for each change in the note, while
/// VoiceOver is running. Everything else about the note is left alone, so
/// nothing changes for anyone not using it.
@MainActor
final class NoteAnnouncer {
  private let controller: AssistantController
  private var last: NoteSnapshot

  init(controller: AssistantController) {
    self.controller = controller
    last = NoteSnapshot(controller)
    observe()
  }

  private func observe() {
    withObservationTracking {
      _ = NoteSnapshot(controller)
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.update()
        self?.observe()
      }
    }
  }

  private func update() {
    let now = NoteSnapshot(controller)
    defer { last = now }
    guard NSWorkspace.shared.isVoiceOverEnabled else { return }
    for line in NoteAnnouncement.changes(from: last, to: now) {
      Self.post(line)
    }
  }

  private static func post(_ line: NoteAnnouncement) {
    let priority: NSAccessibilityPriorityLevel = line.priority == .high ? .high : .medium
    NSAccessibility.post(
      element: NSApplication.shared, notification: .announcementRequested,
      userInfo: [.announcement: line.text, .priority: priority.rawValue])
  }
}
