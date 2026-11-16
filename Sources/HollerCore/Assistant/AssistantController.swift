import Foundation
import Observation

/// Speech capture as the controller sees it. Recording starts on press and
/// transcription runs while the user is still talking; `finish` returns the
/// transcript once the audio is in.
public protocol VoiceInput: Sendable {
  func start(keyTerms: [String]) async throws
  func finish() async throws -> String
  func cancel() async
}

/// Speech out, for an answer read aloud. Speaking again replaces whatever is
/// still being said.
@MainActor
public protocol VoiceOutput: AnyObject {
  func speak(_ text: String)
  func stop()
}

/// The app's state machine: hotkey presses in, the note's contents out.
///
/// - Hold the hotkey: listen. Release: transcribe while reading Herdr, then
///   ask the assistant.
/// - A quick tap (under `tapThreshold`) is not a question; it closes the note.
/// - Holding the hotkey while Holler transcribes or thinks cuts in: once held
///   past `tapThreshold`, the request in progress is dropped and Holler
///   listens. A shortcut with the hotkey before then leaves the request running.
/// - Each request carries on the session's conversation, which outlives the
///   note; `newConversation()` clears it. `reopen()` shows the last note's
///   exchanges again while the session remembers them, never their cards.
/// - An action only runs from `confirm(_:)`, i.e. a click or Return, or, with
///   `runsSimpleActionsWithoutACard` on, when the session ends a simple
///   action's countdown (ADR 0001). Closing the note drops any still waiting
///   or counting down.
/// - While a card waits or counts down, Holler holds the keyboard so Return
///   confirms it, or runs it at once. Any other key gives the keyboard back,
///   until the next card comes; a countdown carries on regardless.
/// - Holding the hotkey to speak pauses every countdown, before the mic
///   starts, until that request is answered: a correction drops the paused
///   action, and otherwise each countdown carries on from where it stopped.
///   A request that fails, a press that hears nothing or turns out to be a
///   shortcut resumes them too; cutting in keeps them paused for the new
///   request, and closing the note drops them.
/// - Asking to see an agent, or clicking its row in a summary, jumps to it
///   and closes the note.
/// - An answer is read aloud while `readsAnswersAloud` is on, unless the user
///   asked to just see it, and otherwise only when they asked to hear it
///   (ADR 0002). Pressing the hotkey or closing the note stops it.
/// - An alert ("tell me when the api agent finishes") shows as a quiet note
///   when it fires: it opens the note if it's closed, joins it if it's open,
///   and is never spoken or given the keyboard.
/// - The request that opens the note shows the agent list the moment the key
///   is released, a row per agent, until its answer replaces it.
@MainActor @Observable
public final class AssistantController {
  public enum Phase: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case thinking
    case ready
    case failed(String)
  }

  /// A confirm card in the note, for one action.
  public struct Card: Identifiable, Equatable, Sendable {
    public let id: String
    /// What the card shows, in its action's words.
    public let content: ConfirmCard
    /// The latest status the session announced for this action.
    public var status: ActionStatus

    public init(id: String, content: ConfirmCard, status: ActionStatus = .waiting(because: nil)) {
      self.id = id
      self.content = content
      self.status = status
    }
  }

  /// One spoken request and what came back.
  public struct Exchange: Identifiable, Equatable, Sendable {
    public let id: Int
    public var request: String
    /// Progress while the assistant works ("Read 6 agents"); nil once answered or failed.
    public var activity: String?
    public var answer: String?
    /// True when the answer is being read aloud, so a screen reader stays quiet.
    public var readAloud: Bool
    public var actions: [Card]
    /// Cards it showed in a note that has since closed. A reopened note
    /// leaves them out: closing the note is how you drop a waiting card.
    public var cardsLeftOut: Int
    /// True for an alert that fired: `request` is what the user asked to be
    /// told, some time ago, and `answer` what happened.
    public var fromAlert: Bool

    public init(
      id: Int, request: String, activity: String? = nil, answer: String? = nil, readAloud: Bool = false,
      actions: [Card] = [], cardsLeftOut: Int = 0, fromAlert: Bool = false
    ) {
      self.id = id
      self.request = request
      self.activity = activity
      self.answer = answer
      self.readAloud = readAloud
      self.actions = actions
      self.cardsLeftOut = cardsLeftOut
      self.fromAlert = fromAlert
    }
  }

  public private(set) var phase: Phase = .idle {
    // The list stands only while Holler works on the request that opened
    // the note: the answer, an error, a cut-in or closing the note ends it.
    didSet { if phase != .transcribing, phase != .thinking { agentList = nil } }
  }
  public private(set) var exchanges: [Exchange] = []
  /// The agent list: a row per agent, shown the moment the key is released,
  /// from the snapshot the request starts from and kept current with Herdr's
  /// events, until the answer replaces it. Only the request that opens the
  /// note shows one; nil otherwise.
  public private(set) var agentList: [AgentRow]?
  /// A short-lived hint under the header, e.g. "Didn't catch that".
  public private(set) var notice: String?

  /// True once the mic is actually capturing, which can take a moment (up to
  /// a few seconds on Bluetooth). Until then the note says "Connecting…".
  public private(set) var isMicLive = false

  /// The menu's "Run Simple Actions Without a Card": whether a simple action
  /// runs after a countdown instead of waiting on its card (ADR 0001). The
  /// app keeps it across launches; off until the user turns it on.
  public var runsSimpleActionsWithoutACard = false

  /// The menu's "Read Answers Aloud": whether every answer gets a spoken
  /// version, told to the model with each request (ADR 0002). On until the
  /// user turns it off; the app keeps it across launches.
  public var readsAnswersAloud = true

  public var isVisible: Bool { phase != .idle }

  /// How much of the note is on screen.
  public enum Form: Equatable, Sendable { case hidden, pill, note }
  /// What the mark is doing: still as a logo, moving with your voice, or rippling while Holler works.
  public enum MarkMotion: Equatable, Sendable { case still, listening, working }

  /// Nothing while idle; the pill while you speak and Holler works; the note
  /// once there's something to read: the agent list, an answer, a confirm
  /// card or an error. Once open, it stays open for follow-ups until it's closed.
  public var form: Form {
    switch phase {
    case .idle: return .hidden
    case .failed: return .note
    case .listening, .transcribing, .thinking, .ready:
      // A finished exchange has an answer, or failed with its error shown.
      let hasSomethingToRead = notice != nil || agentList != nil || exchanges.contains { $0.activity == nil }
      return hasSomethingToRead ? .note : .pill
    }
  }

  /// The status in the pill or the note's header while something is in progress.
  public var status: String? {
    switch phase {
    case .idle, .ready, .failed: nil
    case .listening: isMicLive ? "Listening…" : "Connecting…"
    case .transcribing: "Transcribing…"
    case .thinking: exchanges.last?.activity ?? "Working on it…"
    }
  }

  public var mark: MarkMotion {
    switch phase {
    case .listening: isMicLive ? .listening : .working
    case .transcribing, .thinking: .working
    case .idle, .ready, .failed: .still
    }
  }
  public var hasWaitingActions: Bool { newestWaitingAction != nil }

  /// Whether `reopen()` has a closed note to show again.
  public var canReopen: Bool { phase == .idle && !lastNote.isEmpty }

  /// Whether Holler holds the keyboard, so Return confirms the newest waiting
  /// card, or runs it at once if it's counting down: while one waits or
  /// counts, unless another key has handed the keyboard back.
  public var holdsKeyboard: Bool { hasWaitingActions && !keyboardHandedBack }

  /// The card Return confirms, or runs at once: the last one in the note
  /// that's still waiting or counting down.
  public var newestWaitingAction: Card.ID? {
    exchanges.lazy.reversed().flatMap { $0.actions.reversed() }.first { $0.status.isUndecided }?.id
  }

  /// Cues for the app's chimes: when the mic goes live, and when a question
  /// that went live is released. Always in pairs; a cancelled or tapped press
  /// that never went live plays neither.
  public var onListeningStarted: () -> Void = {}
  public var onListeningEnded: () -> Void = {}
  /// Cue for the app to bring the terminal forward, once a jump has closed the note.
  public var onJumped: (HerdrAgent) -> Void = { _ in }
  /// One `timingLine` per answered or failed request, for the app's log.
  public var onTiming: (String) -> Void = { _ in }
  /// The key you hold to ask, for the notices that name it.
  public var hotkey: Settings.Hotkey = .default

  private let voice: any VoiceInput
  private let speaker: (any VoiceOutput)?
  private let herdr: HerdrClient
  private let makeSession: @Sendable () -> AssistantSession
  private let tapThreshold: Duration
  private let clock = ContinuousClock()
  /// How long a simple action counts down before it runs (ADR 0001).
  private static let countdown: Duration = .seconds(3)

  private var session: AssistantSession?
  /// The settings from the last reload, for a session made after it.
  private var sessionSettings: (model: String, effort: String?, gateway: any ChatCompleting)?
  private var keyTerms: [String] = SpeechHints.fixedTerms
  private var pressedAt: ContinuousClock.Instant?
  private var recording: Task<Void, any Error>?
  /// The last discarded recording's mic teardown. The next press waits for it,
  /// because `VoiceInput.cancel()` isn't tied to a press and would otherwise
  /// cancel the new capture instead.
  private var teardown: Task<Void, Never>?
  /// Bumped on every press, so a slow mic start can't cue a later press.
  private var press = 0
  private var startCuePlayed = false
  private var keyTermsLoaded = false
  private var work: Task<Void, Never>?
  /// A press while Holler transcribes or thinks, waiting out `tapThreshold`
  /// before it drops that request and listens.
  private var cutIn: Task<Void, Never>?
  /// Cards following their statuses after a confirm or cancel, joined into one task.
  private var cardUpdates: Task<Void, Never>?
  /// Session calls from closing the note or a new conversation, run in order
  /// in one task that the next request waits for.
  private var sessionCalls: Task<Void, Never>?
  /// Cards confirmed or cancelled whose new status may not be back yet, so
  /// closing the note doesn't drop them.
  private var answeredCards: Set<Card.ID> = []
  /// Set by a key other than Return while a card waits, so you can type in
  /// your app again; cleared when the next card comes.
  private var keyboardHandedBack = false
  /// The latest press's pause of the session's countdowns, which the request
  /// it becomes resumes once it's answered, fails or is dropped. A press that
  /// cuts in takes over with its own.
  private var countdownPause: CountdownPause?
  /// Bumped on dismiss, so work started for a closed note can't touch a new one.
  private var generation = 0
  /// Bumped when a request starts and when one is dropped, by closing the
  /// note or cutting in, so only the request in progress can touch the note.
  private var request = 0
  /// The last closed note's answered exchanges, without their cards, for `reopen()`.
  private var lastNote: [Exchange] = []
  private var nextExchangeId = 1

  public init(
    voice: any VoiceInput, speaker: (any VoiceOutput)? = nil, herdr: HerdrClient,
    tapThreshold: Duration = .milliseconds(300), makeSession: @escaping @Sendable () -> AssistantSession
  ) {
    self.voice = voice
    self.speaker = speaker
    self.herdr = herdr
    self.tapThreshold = tapThreshold
    self.makeSession = makeSession
  }

  // MARK: - Hotkey

  public func hotkeyDown() {
    switch phase {
    case .listening: return
    case .transcribing, .thinking:
      // Wait to see whether it's a tap or a shortcut before dropping anything.
      guard cutIn == nil else { return }
      let (pressed, threshold) = (clock.now, tapThreshold)
      cutIn = Task {
        try? await Task.sleep(for: threshold)
        guard !Task.isCancelled else { return }
        cutIn = nil
        if phase == .transcribing || phase == .thinking { dropRequest() }
        listen(pressedAt: pressed)
      }
    case .idle, .ready, .failed:
      listen(pressedAt: clock.now)
    }
  }

  private func listen(pressedAt: ContinuousClock.Instant) {
    // Don't talk over the user, or into the mic.
    speaker?.stop()
    // Nor run an action while they may be correcting it.
    pauseCountdowns()
    press += 1
    let press = press
    self.pressedAt = pressedAt
    notice = nil
    isMicLive = false
    startCuePlayed = false
    phase = .listening
    let (voice, terms, teardown) = (voice, keyTerms, teardown)
    let recording = Task {
      await teardown?.value
      try Task.checkCancellation()
      try await voice.start(keyTerms: terms)
    }
    self.recording = recording
    Task {
      guard case .success = await recording.result, self.press == press, phase == .listening else { return }
      isMicLive = true
      startCuePlayed = true
      onListeningStarted()
    }
    if !keyTermsLoaded { refreshKeyTerms() }
  }

  public func hotkeyUp() {
    if let cutIn {
      // Let go before cutting in: a tap, which closes the note.
      cutIn.cancel()
      self.cutIn = nil
      dismiss()
      return
    }
    guard phase == .listening, let pressedAt else { return }
    self.pressedAt = nil
    if clock.now - pressedAt < tapThreshold {
      // A tap, not a question: close the note (which drops the audio).
      dismiss()
      return
    }
    if startCuePlayed { onListeningEnded() }
    startCuePlayed = false
    isMicLive = false
    phase = .transcribing
    // Herdr is read while the transcript comes in, so it's ready when that is.
    _ = currentSession()
    callSession { await $0.prepare() }
    request += 1
    let (recording, request, released) = (recording, request, clock.now)
    work = Task { await transcribeAndAsk(recording, request: request, released: released) }
  }

  /// Another key went down while the hotkey was held (e.g. ⌥3 typing "#"):
  /// it was a keyboard shortcut, not a question. One before a cut-in leaves
  /// the request in progress running.
  public func hotkeyCancelled() {
    if let cutIn {
      cutIn.cancel()
      self.cutIn = nil
      return
    }
    guard phase == .listening else { return }
    pressedAt = nil
    if exchanges.isEmpty {
      dismiss()
    } else {
      stopListening()
      resumeCountdowns()
      phase = .ready
    }
  }

  // MARK: - Note actions

  /// Asks without speech: a typed request, and the way previews and tests
  /// drive the controller. Like cutting in, it drops any request in progress,
  /// and any press still being heard.
  public func ask(_ text: String) {
    cutIn?.cancel()
    cutIn = nil
    if phase == .listening {
      pressedAt = nil
      stopListening()
    }
    dropRequest()
    request += 1
    let (request, asked) = (request, clock.now)
    work = Task { await run(text, request: request, transcript: nil, startedAt: asked) }
  }

  /// Shows the last closed note's exchanges again, if the session still
  /// remembers the conversation they're part of. Never their cards: closing
  /// the note dropped any still waiting. Once the conversation has ended,
  /// the note says so instead.
  public func reopen() {
    guard canReopen, let session else { return }
    let (note, generation) = (lastNote, generation)
    work = Task {
      await sessionCalls?.value
      let remembered = await session.remembers()
      guard self.generation == generation, phase == .idle else { return }
      if remembered {
        exchanges = note
      } else {
        lastNote = []
        notice = "That conversation has ended, so there's nothing to reopen."
      }
      phase = .ready
    }
  }

  /// Jumps to the agent a summary row names, as asking to see it would: the
  /// note closes and the terminal comes forward, unless a card is waiting,
  /// which keeps the note and the keyboard. The agent is found by name in a
  /// fresh Herdr snapshot; one that has gone, is hidden, or shares its name
  /// leaves the note open with the reason. Ignored while Holler listens or works.
  public func jump(to row: AgentRow) {
    switch phase {
    case .ready, .failed: break
    case .idle, .listening, .transcribing, .thinking: return
    }
    let (herdr, generation, request) = (herdr, generation, request)
    work = Task {
      do {
        let shown =
          if let paneId = row.paneId {
            try await herdr.focus(paneId: paneId)
          } else {
            try await herdr.focus(workspace: row.workspace, tab: row.tab)
          }
        guard self.generation == generation, self.request == request else { return }
        notice = nil
        guard !hasWaitingActions else { return }
        dismiss()
        onJumped(shown)
      } catch {
        guard self.generation == generation, self.request == request else { return }
        notice = "Couldn't show \(row.name): \(AssistantSession.describe(error))."
      }
    }
  }

  /// Asks the session to run the action. The card follows the statuses the
  /// session announces; one that isn't waiting any more is left alone.
  public func confirm(_ actionId: String) {
    guard let session else { return }
    answeredCards.insert(actionId)
    let (events, announce) = AsyncStream.makeStream(of: AssistantEvent.self)
    Task {
      _ = try? await session.confirm(actionId) { announce.yield($0) }
      announce.finish()
    }
    showStatuses(events)
  }

  /// Return in the note: confirms the newest card still waiting, if any.
  public func confirmNewest() {
    if let newestWaitingAction { confirm(newestWaitingAction) }
  }

  /// A key other than Return while Holler holds the keyboard: gives it back
  /// to the app you were in. The card still waits for a click, and the next
  /// card takes the keyboard again.
  public func handBackKeyboard() {
    keyboardHandedBack = true
  }

  public func cancel(_ actionId: String) {
    guard let session else { return }
    answeredCards.insert(actionId)
    let (events, announce) = AsyncStream.makeStream(of: AssistantEvent.self)
    Task {
      await session.cancel(actionId) { announce.yield($0) }
      announce.finish()
    }
    showStatuses(events)
  }

  /// Closes the note. The session keeps the conversation; any card still
  /// waiting is dropped unsent. Its answered exchanges are kept, without
  /// their cards, for `reopen()`.
  public func dismiss() {
    speaker?.stop()
    // While transcribing, this only stops a mic that is still connecting;
    // once the mic is up, `transcribeAndAsk` has finished it.
    if phase == .listening || phase == .transcribing { stopListening() }
    cutIn?.cancel()
    cutIn = nil
    let answered = exchanges.filter { $0.answer != nil }
    if !answered.isEmpty {
      lastNote = answered.map { exchange in
        var closed = exchange
        closed.cardsLeftOut += closed.actions.count
        closed.actions = []
        return closed
      }
    }
    let undecided = exchanges.flatMap(\.actions).filter { $0.status.isUndecided && !answeredCards.contains($0.id) }.map(\.id)
    if !undecided.isEmpty { drop(undecided) }
    // Paused countdowns were just dropped with their cards; this lets any
    // countdown that starts later run.
    resumeCountdowns()
    answeredCards = []
    keyboardHandedBack = false
    generation += 1
    request += 1
    work?.cancel()
    work = nil
    cardUpdates = nil
    exchanges = []
    notice = nil
    phase = .idle
  }

  /// Closes the note and starts a fresh conversation.
  public func newConversation() {
    dismiss()
    lastNote = []
    callSession { await $0.newConversation() }
  }

  /// New settings from a reload: the next request asks `model` with `effort`
  /// through `gateway`, in the same conversation. A request already running
  /// finishes as it began, and a session made later starts with these.
  public func updateSession(model: String, effort: String?, gateway: any ChatCompleting) {
    sessionSettings = (model, effort, gateway)
    callSession { await $0.update(model: model, effort: effort, gateway: gateway) }
  }

  /// Waits for in-flight transcription, assistant work or card updates. For tests.
  func settle() async {
    await cutIn?.value
    await work?.value
    await cardUpdates?.value
    await sessionCalls?.value
  }

  /// Puts the note into a fixed state, for rendering previews.
  public func showPreview(
    phase: Phase, exchanges: [Exchange], notice: String? = nil, micLive: Bool = true, agentList: [AgentRow]? = nil
  ) {
    self.phase = phase
    self.isMicLive = micLive
    self.exchanges = exchanges
    self.notice = notice
    self.agentList = agentList
  }

  // MARK: - Private

  /// Drops the request in progress, if any, for a cut-in or a typed request:
  /// its transcript or answer never lands, any cards it queued are dropped
  /// unsent, and its exchange leaves the note. Earlier exchanges stay.
  private func dropRequest() {
    // A mic still connecting when the key was let go may not have stopped yet.
    if phase == .transcribing { stopListening() }
    request += 1
    work?.cancel()
    work = nil
    exchanges.removeAll { $0.answer == nil && $0.activity != nil }
  }

  private func transcribeAndAsk(
    _ recording: Task<Void, any Error>?, request: Int, released: ContinuousClock.Instant
  ) async {
    do {
      try await recording?.value
      // Dropped while the mic was still connecting: whatever dropped it stops the mic.
      try Task.checkCancellation()
      // The mic is up and about to be finished, so there is nothing left for
      // `stopListening()` to tear down.
      self.recording = nil
      let text = try await voice.finish().trimmingCharacters(in: .whitespacesAndNewlines)
      let transcript = clock.now - released
      guard self.request == request else { return }
      guard !text.isEmpty else {
        // A note with nothing in it closes; one showing the agent list stays
        // to say so, rather than snapping shut.
        if exchanges.isEmpty, agentList == nil {
          dismiss()
        } else {
          notice = "Didn't catch that. Hold \(hotkey.label) and try again."
          resumeCountdowns()
          phase = .ready
        }
        return
      }
      await run(text, request: request, transcript: transcript, startedAt: released)
    } catch {
      guard self.request == request else { return }
      onTiming(Self.failureLine(error, transcript: nil, total: clock.now - released))
      resumeCountdowns()
      phase = .failed(AssistantSession.describe(error))
    }
  }

  private func run(
    _ text: String, request: Int, transcript: Duration?, startedAt: ContinuousClock.Instant
  ) async {
    let session = currentSession()
    let id = nextExchangeId
    nextExchangeId += 1
    exchanges.append(Exchange(id: id, request: text, activity: "Checking your agents…"))
    phase = .thinking

    do {
      await sessionCalls?.value
      let (countdown, generation) = (runsSimpleActionsWithoutACard ? Self.countdown : nil, generation)
      let turn = try await session.ask(text, countdown: countdown, readAloud: readsAnswersAloud) { event in
        Task { @MainActor in self.apply(event, to: id, request: request, generation: generation) }
      }
      guard self.request == request else {
        // The note closed, or a press cut in, before this answer came, so it
        // showed no cards. Any paused countdown is the newer press's to resume.
        let queued = turn.actions.map(\.id)
        if !queued.isEmpty { drop(queued) }
        return
      }
      onTiming(Self.timingLine(turn, transcript: transcript, total: clock.now - startedAt))
      // One line per pane a read couldn't deliver in full. `holler stats`
      // skips these, since only "turn totalMs=" lines are turns.
      for problem in turn.readProblems { onTiming("turn read \(problem)") }
      update(id) {
        $0.activity = nil
        $0.answer = turn.answer
        $0.readAloud = turn.spoken != nil
        $0.actions = turn.actions.map { Card(id: $0.id, content: $0.card, status: $0.firstStatus) }
      }
      for replaced in turn.replaced { setCardStatus(replaced, .replaced) }
      // Answered: a paused action this replaced stays dropped, and the rest
      // count on from where they stopped.
      resumeCountdowns()
      if !turn.actions.isEmpty { keyboardHandedBack = false }
      // You've gone to look, so the note closes. A waiting card keeps it, and
      // the keyboard, so Return can't land in the terminal.
      if let shown = turn.focused, !hasWaitingActions {
        dismiss()
        onJumped(shown)
        return
      }
      phase = .ready
      if let spoken = turn.spoken { speaker?.speak(spoken) }
      refreshKeyTerms()
    } catch {
      guard self.request == request else { return }
      onTiming(Self.failureLine(error, transcript: transcript, total: clock.now - startedAt))
      update(id) { $0.activity = nil }
      resumeCountdowns()
      phase = .failed(AssistantSession.describe(error))
    }
  }

  /// Where the time went, from letting go of the key (or a typed request) to
  /// the answer: numbers and ids only, never what was said. Holler's tools run
  /// in the gap between Herdr and the model. `herdrMs` is the wait for Herdr
  /// once the transcript is in; `readMs` is how long Herdr took, from release
  /// when `readOnRelease` is true, so a `readMs` under `transcriptMs` means
  /// the panes were read before the transcript arrived. `events` is whether
  /// Herdr's event stream was up: live, down, or off without a watcher.
  /// `tools` lists the tools called in order, a `!` marking each that failed.
  nonisolated static func timingLine(_ turn: AssistantTurn, transcript: Duration?, total: Duration) -> String {
    let tools = turn.elapsed - turn.modelElapsed - turn.herdrElapsed
    return "turn totalMs=\(ms(total)) transcriptMs=\(transcript.map(ms) ?? "n/a") herdrMs=\(ms(turn.herdrElapsed)) "
      + "readMs=\(ms(turn.readElapsed)) readOnRelease=\(turn.readOnRelease) "
      + "agentsRead=\(turn.agentsRead) events=\(turn.eventsLive.map { $0 ? "live" : "down" } ?? "off") "
      + "modelMs=\(ms(turn.modelElapsed)) roundMs=\(turn.roundModelElapsed.map(ms).joined(separator: ",")) "
      + "toolsMs=\(ms(tools)) rounds=\(turn.iterations) tools=\(toolNames(turn.tools)) "
      + "tokensIn=\(turn.usage.inputTokens) tokensCached=\(turn.usage.cachedTokens) tokensOut=\(turn.usage.outputTokens) "
      + "actions=\(turn.actions.count) jumped=\(turn.focused != nil) readAloud=\(turn.spoken != nil) "
      + "request=\(turn.requestIds.last ?? "n/a")"
  }

  static func failureLine(_ error: any Error, transcript: Duration?, total: Duration) -> String {
    "turn failed totalMs=\(ms(total)) transcriptMs=\(transcript.map(ms) ?? "n/a") error=\(AssistantSession.describe(error))"
  }

  private nonisolated static func toolNames(_ tools: [(name: String, failed: Bool)]) -> String {
    tools.isEmpty ? "none" : tools.map { $0.name + ($0.failed ? "!" : "") }.joined(separator: ",")
  }

  private nonisolated static func ms(_ duration: Duration) -> String {
    String(Int((duration / .milliseconds(1)).rounded()))
  }

  private func apply(_ event: AssistantEvent, to id: Int, request: Int, generation: Int) {
    if case .status(let actionId, let status) = event {
      // A card moves on after its answer too: its countdown ticks, it runs,
      // or it falls back to waiting. Shown as long as this note is open.
      guard self.generation == generation else { return }
      return setCardStatus(actionId, status)
    }
    guard self.request == request, exchanges.first(where: { $0.id == id })?.answer == nil else { return }
    switch event {
    case .reading(let agents):
      update(id) { $0.activity = "Reviewing \(agents.count) agent\(agents.count == 1 ? "" : "s")…" }
    case .thinking(let iteration) where iteration > 1:
      update(id) { $0.activity = "Looking closer…" }
    case .thinking, .queued, .status:
      break
    }
  }

  private func update(_ id: Int, _ change: (inout Exchange) -> Void) {
    guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
    change(&exchanges[index])
  }

  /// Shows each status the session announces on its card, in the order it
  /// announced them, while this note is open.
  private func showStatuses(_ events: AsyncStream<AssistantEvent>) {
    let generation = generation
    let updates = Task {
      for await event in events {
        guard self.generation == generation, case .status(let actionId, let status) = event else { continue }
        setCardStatus(actionId, status)
      }
    }
    let previous = cardUpdates
    cardUpdates = Task {
      await previous?.value
      await updates.value
    }
  }

  private func setCardStatus(_ actionId: Card.ID, _ status: ActionStatus) {
    for exchangeIndex in exchanges.indices {
      if let cardIndex = exchanges[exchangeIndex].actions.firstIndex(where: { $0.id == actionId }) {
        exchanges[exchangeIndex].actions[cardIndex].status = status
      }
    }
  }

  /// The session, made on first use with the settings of the last reload, if any.
  private func currentSession() -> AssistantSession {
    if let session { return session }
    let made = makeSession()
    session = made
    if let settings = sessionSettings {
      let (model, effort, gateway) = settings
      callSession { await $0.update(model: model, effort: effort, gateway: gateway) }
    }
    Task {
      for await fired in await made.alerts() { show(fired) }
    }
    // Followed in order with the session calls, so the first request's
    // `prepare()` finds the follower in and its list isn't lost.
    callSession { session in
      let lists = await session.agentLists()
      Task { @MainActor in
        for await list in lists { self.show(list) }
      }
    }
    return made
  }

  /// Shows the agent list a request read, while Holler works on the request
  /// that opens the note: with nothing else to read yet, neither an answer
  /// nor an error. A later list, from a change, keeps it current; one with
  /// no agents left takes it away, and no agents to begin with shows nothing.
  private func show(_ list: [AgentRow]) {
    guard phase == .transcribing || phase == .thinking, notice == nil, !exchanges.contains(where: { $0.activity == nil })
    else { return }
    agentList = list.isEmpty ? nil : list
  }

  /// Shows an alert that has fired: the user's words and what happened, as
  /// an exchange of its own. The note opens for it if it was closed; while
  /// Holler listens or works, it waits in the note behind the pill.
  private func show(_ fired: Alert.Fired) {
    let id = nextExchangeId
    nextExchangeId += 1
    exchanges.append(Exchange(id: id, request: fired.alert.request, answer: fired.answer, fromAlert: true))
    // Something to read now, so an agent list stands down.
    agentList = nil
    if phase == .idle { phase = .ready }
  }

  /// Drops the cards of a note that has closed, or of an answer that came too
  /// late for one. Their countdowns stop here and now, since the drop waits
  /// its turn behind earlier session calls and a countdown could end first.
  private func drop(_ actionIds: [Card.ID]) {
    session?.stopCountdowns(actionIds)
    callSession { await $0.drop(actionIds) }
  }

  /// Pauses the session's countdowns for a press, at once, so none runs
  /// while the user may be correcting it. No session yet means no countdowns.
  private func pauseCountdowns() {
    guard let session else { return }
    countdownPause = session.pauseCountdowns()
  }

  /// Lets the countdowns a press paused carry on, after any session call
  /// before it, like the drop when the note closes. By the time it gets
  /// there the next press may have paused them again, and then it does
  /// nothing, since only that press's own pause lifts.
  private func resumeCountdowns() {
    guard let pause = countdownPause else { return }
    countdownPause = nil
    callSession { await $0.resumeCountdowns(pause) }
  }

  /// Runs a session call after any before it, so the next request sees its effect.
  private func callSession(_ call: @escaping @Sendable (AssistantSession) async -> Void) {
    guard let session else { return }
    let previous = sessionCalls
    sessionCalls = Task {
      await previous?.value
      await call(session)
    }
  }

  /// Drops the current recording, silently: no stop chime for a press that
  /// isn't going ahead.
  private func stopListening() {
    isMicLive = false
    startCuePlayed = false
    guard let recording else { return }
    self.recording = nil
    // Cancelling makes a mic start that's still connecting give up early.
    recording.cancel()
    let (voice, previous) = (voice, teardown)
    teardown = Task {
      await previous?.value
      _ = await recording.result
      await voice.cancel()
    }
  }

  /// Keeps the speech key terms in step with the agents that are running,
  /// ready for the next press: loaded on the first press and refreshed after
  /// each answer, never per keystroke. Off the hot path.
  private func refreshKeyTerms() {
    let herdr = herdr
    Task {
      if let agents = try? await herdr.agents() {
        keyTerms = SpeechHints.keyTerms(for: agents)
        keyTermsLoaded = true
      }
    }
  }
}
