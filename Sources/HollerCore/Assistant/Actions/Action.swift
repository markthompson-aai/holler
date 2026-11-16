import Foundation

/// Something the model wants done in Herdr, held by the session until the
/// user confirms it or its countdown ends.
public struct Action: Sendable, Identifiable {
  public let id: String
  /// The action's own definition: how it runs, its notes and its card.
  let definition: any ActionDefinition
  /// Seconds it counts down before it runs, once its turn has ended, rather
  /// than waiting on its card; nil when it waits (ADR 0001).
  public let countdown: Int?
  /// Why it waits on its card when the user has allowed simple actions to
  /// run without one, worded for the card: "api is working, so this waits
  /// for you." Nil when it counts down, when the setting is off, and for a
  /// kind that always waits, like a close.
  public let waitsBecause: String?

  /// One that waits on its card, saying why if it might have counted down.
  init(id: String, _ definition: any ActionDefinition, waitsBecause: String? = nil) {
    self.id = id
    self.definition = definition
    countdown = nil
    self.waitsBecause = waitsBecause
  }

  /// One that runs after counting down this many seconds, so its card has
  /// no reason to wait.
  init(id: String, _ definition: any ActionDefinition, countdown: Int) {
    self.id = id
    self.definition = definition
    self.countdown = countdown
    waitsBecause = nil
  }

  /// What its confirm card shows.
  public var card: ConfirmCard { definition.card }

  /// Where its card starts: counting down, or waiting, with why if it might
  /// have counted down.
  public var firstStatus: ActionStatus {
    countdown.map(ActionStatus.countingDown) ?? .waiting(because: waitsBecause)
  }
}

/// Whether an action may run after a countdown instead of waiting on its
/// card, once the user has allowed that (ADR 0001).
enum Simplicity: Sendable, Equatable {
  /// Simple enough to count down.
  case simple
  /// A kind that can count down, but this one waits, for the reason its card
  /// gives: "api is working, so this waits for you."
  case waits(because: String)
  /// A kind that always waits on its card, like a close; the card says
  /// nothing about it.
  case never

  /// What a card that waits says about why: the reason for `waits`, and
  /// nothing for a kind that never counts down.
  var waitReason: String? {
    if case .waits(let because) = self { because } else { nil }
  }
}

/// Text an agent would run rather than read. Claude Code and Codex take
/// input that starts with `!` as a shell command, run there and then, and
/// input that starts with `/` as a slash command. A message or first task
/// like that never counts down: it waits on its card, which says what it is.
enum DirectInput: Sendable, Equatable {
  case shellCommand
  case slashCommand

  /// Nil for ordinary text, and for no text at all.
  init?(_ text: String?) {
    switch text?.first(where: { !$0.isWhitespace }) {
    case "!": self = .shellCommand
    case "/": self = .slashCommand
    default: return nil
    }
  }

  /// The warning line on its card.
  var warning: String {
    switch self {
    case .shellCommand: "Starts with !, so the agent runs it as a shell command rather than reading it."
    case .slashCommand: "Starts with /, so the agent may run it as a slash command rather than read it."
    }
  }

  /// Why its card waits, once simple actions run without one.
  var waitReason: String {
    switch self {
    case .shellCommand: "It starts with !, so this waits for you."
    case .slashCommand: "It starts with /, so this waits for you."
    }
  }
}

/// How an action came to run: the user confirmed its card, or its countdown
/// ended without them cancelling it.
enum ActionTrigger: Sendable {
  case confirmed
  case countdownEnded

  /// How a note on the action opens, for the model: "The user confirmed a1".
  func opening(_ id: String) -> String {
    switch self {
    case .confirmed: "The user confirmed \(id)"
    case .countdownEnded: "\(id)'s countdown ended"
    }
  }
}

/// One kind of action: running it once the user confirms or its countdown
/// ends, the notes for the model, and its confirm card. Its file also holds
/// the tool that queues it and that tool's checks, so everything about the
/// kind is in one place.
protocol ActionDefinition: Sendable {
  var card: ConfirmCard { get }
  /// The answer when the turn ends on its card and the model wrote nothing
  /// alongside it: "Ready to send to api / main."
  var ready: String { get }
  /// The same when the card counts down rather than waits: "Sending to api / main."
  var underway: String { get }
  /// The pane ids of the agents it's about, which join the conversation's focus.
  var about: [String] { get }
  /// Whether it's simple enough to run after a countdown instead of waiting
  /// on a card, once the user has allowed that (ADR 0001), judged from its
  /// target as the tool found it, and if not, why. `never` for a kind that
  /// always waits.
  var simplicity: Simplicity { get }
  /// The same judgement against a fresh snapshot when the countdown ends, so
  /// one whose agent has started working, got blocked or gone, or whose
  /// workspace has closed, gets a card that says so.
  func simplicity(in state: HerdrState) -> Simplicity
  /// Does it in Herdr. Returns the agent messaged or started, if any, and the
  /// note telling the model it happened, opening with how it came to run.
  func run(_ id: String, herdr: HerdrClient, by trigger: ActionTrigger) async throws -> (agent: HerdrAgent?, note: String)
  /// Why it failed, for the user, when running it threw `error`.
  func failedReason(_ error: any Error) -> String
  /// The note for the model when running it threw `error`.
  func failedNote(_ id: String, _ error: any Error, by trigger: ActionTrigger) -> String
  /// The note for the model when the user cancelled it, from its card or
  /// while it was counting down.
  func cancelledNote(_ id: String, countingDown: Bool) -> String
  /// The note for the model when the request that queued it failed.
  func withdrawnNote(_ id: String) -> String
  /// The note for the model when the note closed with its card still waiting
  /// or counting down.
  func droppedNote(_ id: String, countingDown: Bool) -> String
  /// The note for the model when a correction, `newer`, replaced its waiting card.
  func replacedNote(_ id: String, by newer: String) -> String
}

extension ActionDefinition {
  var underway: String { ready }
  var simplicity: Simplicity { .never }
  func simplicity(in state: HerdrState) -> Simplicity { .never }
  func failedReason(_ error: any Error) -> String { AssistantSession.describe(error) }
  func cancelledNote(_ id: String, countingDown: Bool) -> String {
    "The user cancelled \(id)\(countingDown ? " during its countdown" : ""); nothing was done."
  }
  func withdrawnNote(_ id: String) -> String {
    "\(id) was dropped because the request that queued it failed; the user never saw it and nothing was done."
  }
  func droppedNote(_ id: String, countingDown: Bool) -> String {
    countingDown
      ? "\(id) was cancelled during the countdown, when the user closed the note; nothing was done."
      : "\(id) was dropped because the user closed the note without confirming it; nothing was done."
  }
  func replacedNote(_ id: String, by newer: String) -> String {
    "\(id) was dropped because \(newer) replaced it as a correction; nothing was done."
  }
}

/// What a confirm card shows for one action, worded by the action, so the
/// note and the CLI say the same thing.
public struct ConfirmCard: Sendable, Equatable {
  /// Which kind of action, for the note to pick its icon.
  public enum Kind: Sendable, Equatable {
    case send
    case start
    case close
    case interrupt
  }

  /// A line under the body, e.g. one agent a close would stop.
  public struct Detail: Sendable, Equatable {
    public var label: String
    public var text: String?
    /// Shown quietly when there's no text: "No output yet."
    public var placeholder: String?

    public init(label: String, text: String?, placeholder: String? = nil) {
      self.label = label
      self.text = text
      self.placeholder = placeholder
    }
  }

  /// The card's words for its button and for each status after waiting.
  public struct Words: Sendable, Equatable {
    public var button: String
    public var busy: String
    public var done: String
    public var cancelled: String
    /// Comes before the reason, e.g. "Not sent: …".
    public var failed: String
    /// Comes before the seconds left while the card counts down: "Sending in" 3…
    public var countdown: String
    /// The button while the card counts down: "Send now".
    public var runNow: String

    /// A kind that never counts down can leave out `countdown` and `runNow`.
    public init(
      button: String, busy: String, done: String, cancelled: String, failed: String, countdown: String = "Running in",
      runNow: String = "Run now"
    ) {
      self.button = button
      self.busy = busy
      self.done = done
      self.cancelled = cancelled
      self.failed = failed
      self.countdown = countdown
      self.runNow = runNow
    }
  }

  public var kind: Kind
  /// Quiet, before the target: "Send to".
  public var verb: String
  /// Where it happens: "api / main".
  public var target: String
  public var subtitle: String?
  /// What is sent, e.g. the message.
  public var body: String?
  /// Shown quietly when there's no body: "No task; it will wait for you."
  public var placeholder: String?
  public var details: [Detail]
  public var warnings: [String]
  public var words: Words

  public init(
    kind: Kind, verb: String, target: String, subtitle: String? = nil, body: String? = nil, placeholder: String? = nil,
    details: [Detail] = [], warnings: [String] = [], words: Words
  ) {
    self.kind = kind
    self.verb = verb
    self.target = target
    self.subtitle = subtitle
    self.body = body
    self.placeholder = placeholder
    self.details = details
    self.warnings = warnings
    self.words = words
  }
}
