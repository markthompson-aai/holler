import Foundation
import Synchronization

/// Where an action is: waiting for the user, running in Herdr, or finished one
/// way or another. Only the session changes it; the note shows the latest one
/// announced.
public enum ActionStatus: Sendable, Equatable {
  /// On its card for the user to confirm. Once the user has allowed simple
  /// actions to run without a card, one that might have counted down says
  /// why it waits instead: "api is working, so this waits for you."
  case waiting(because: String?)
  /// Running once this many seconds have passed, unless the user cancels it
  /// or runs it first (ADR 0001).
  case countingDown(Int)
  /// Counting down, but held where it stood while the user holds the key to
  /// speak, until their request is answered.
  case paused
  case busy
  case done
  case cancelled
  /// Why it failed, worded for the user.
  case failed(String)
  /// Dropped unsent: the request that queued it failed, or the note closed
  /// before it was confirmed.
  case withdrawn
  /// Dropped unsent because a later card corrects it.
  case replaced
}

extension ActionStatus {
  /// On its card for the user to confirm, whatever the reason.
  public var isWaiting: Bool {
    if case .waiting = self { true } else { false }
  }

  /// Running when its countdown ends, unless the user steps in. A paused
  /// countdown still counts, for the model too: it carries on once the user's
  /// request is answered.
  public var isCountingDown: Bool {
    switch self {
    case .countingDown, .paused: true
    default: false
    }
  }

  /// Still the user's to confirm or cancel, since it hasn't run yet: waiting
  /// on its card, or counting down, even if paused.
  public var isUndecided: Bool { isWaiting || isCountingDown }
}

/// One press's pause of the countdowns, which only that press's resume lifts.
public struct CountdownPause: Sendable, Equatable {
  fileprivate let number: Int
}

/// The outcome of one spoken request.
public struct AssistantTurn: Sendable {
  /// The request, as spoken or typed. Empty only on a turn built by hand.
  public var request = ""
  public var answer: String
  public var actions: [Action]
  /// Earlier cards this turn's actions replaced, now dropped unsent.
  public var replaced: [String] = []
  /// What to say aloud, when the answer is read aloud: the reply's
  /// <read_aloud> block, written in the same model call as `answer`.
  public var spoken: String?
  /// The agent Herdr switched to, when the user asked to see one. The turn
  /// ends there, without another model call, since the note closes.
  public var focused: HerdrAgent?
  public var usage: ChatUsage
  public var requestIds: [String]
  public var iterations: Int
  public var elapsed: Duration
  /// Time spent waiting on the model, as opposed to running tools.
  public var modelElapsed: Duration
  /// Time spent waiting on the Herdr snapshot and recent output before the
  /// first model call: all of their time, unless they were read on release.
  public var herdrElapsed: Duration = .zero
  /// How long the snapshot and recent output took, wherever they began.
  public var readElapsed: Duration = .zero
  /// Whether they were read on releasing the key, while the transcript came in.
  public var readOnRelease = false
  /// How many agents' recent output was read before the first model call,
  /// counting any that failed to read, since those cost Herdr time too.
  public var agentsRead = 0
  /// Whether Herdr's events were coming in, so changes and waits were timed
  /// as they happened; nil without a watcher.
  public var eventsLive: Bool?
  /// Each model call's share of `modelElapsed`, in order.
  public var roundModelElapsed: [Duration] = []
  /// The tools the model called, round by round in call order, and whether
  /// each one failed, e.g. a close Herdr refused.
  public var tools: [(name: String, failed: Bool)] = []
  /// What the read_agents calls couldn't deliver, one line per pane: an
  /// error, or a marker saying the text is the screen only, timed out or cut.
  /// Logged with the turn, since the model's wording for these is loose.
  public var readProblems: [String] = []
  /// The pane ids of the agents this turn was about: marked by the reply's
  /// <about> block, or read, messaged, closed or jumped to by its tool calls.
  var about: [String] = []
  /// Earlier cards to replace with this turn's actions, by action id, once
  /// the turn succeeds: a failed request shows no cards, so it replaces nothing.
  var replacing: [(old: String, new: String)] = []
  /// Seconds this request's simple actions count down before they run; nil
  /// when every action waits on its card.
  var countdown: Int?
}

public enum AssistantEvent: Sendable {
  case thinking(iteration: Int)
  case reading([HerdrAgent])
  case queued(Action)
  /// An action moved on: its countdown ticked, it was confirmed, cancelled,
  /// run, failed or withdrawn, or it fell back to waiting.
  case status(actionId: String, ActionStatus)
}

/// The conversation with the model: each spoken request, its tool loop, and
/// follow-ups. The conversation outlives the note: it lasts until a request
/// comes more than `conversationWindow` after the previous one, or until
/// `newConversation()`. Holds the only path from a model tool call to
/// `herdr agent prompt`, a new agent or a closed tab, and that path needs
/// `confirm(_:)`, or a countdown the user has allowed and not cancelled
/// (ADR 0001).
public actor AssistantSession {
  public struct Configuration: Sendable {
    public var model: String
    public var maxIterations: Int
    /// Caps each reply: room for a long explanation and its spoken version,
    /// since a reply cut off mid <read_aloud> isn't read at all.
    public var maxTokens: Int
    public var temperature: Double?
    /// Claude's effort level; nil leaves the model's default.
    public var effort: String?
    /// Lines of each agent's screen sent with each request, so a summary takes
    /// one model call instead of a read round first: every agent's on the
    /// first request of a conversation, then only those in focus or changed.
    /// 0 disables.
    public var prefetchLines: Int
    /// Per-agent cap on prefetched output; the model can read more on demand.
    public var prefetchCharacters: Int
    /// Earlier exchanges sent with each request, as text; the oldest drop off first.
    public var rememberedExchanges: Int
    /// How long the conversation is remembered after a request. A request
    /// that comes later starts a fresh one.
    public var conversationWindow: Duration

    public init(
      model: String, maxIterations: Int = 6, maxTokens: Int = 4_000, temperature: Double? = nil,
      effort: String? = nil, prefetchLines: Int = 60, prefetchCharacters: Int = 3_000, rememberedExchanges: Int = 5,
      conversationWindow: Duration = .seconds(20 * 60)
    ) {
      self.model = model
      self.maxIterations = maxIterations
      self.maxTokens = maxTokens
      self.temperature = temperature
      self.effort = effort
      self.prefetchLines = prefetchLines
      self.prefetchCharacters = prefetchCharacters
      self.rememberedExchanges = rememberedExchanges
      self.conversationWindow = conversationWindow
    }
  }

  /// An earlier request and Holler's answer, as later requests carry them.
  private struct Exchange {
    var request: String
    var answer: String
    /// The agents it was about; follow-ups read their recent output.
    var about: [String]
  }

  /// The Herdr snapshot a request starts from, and the agents' screens read with it.
  private struct Look: Sendable {
    var state: HerdrState
    /// The agents whose screens were read, counting any that failed to read.
    var read: [HerdrAgent]
    /// The screens sent in full.
    var recent: [String: String]
    /// Every screen read, including those only checked for what's new.
    var screens: [String: String]
    /// The watcher's picture, when there is a watcher.
    var picture: HerdrWatcher.Picture?
    /// When the user last asked, if they have since Holler started.
    var lastAsked: Date?
    /// For agents working all along since then: the lines new on their screens.
    var progress: [String: [String]]
    var elapsed: Duration
  }

  /// What a round of tool calls leaves the turn to do.
  private struct Round {
    /// Set by a tool that ends the turn, like a jump.
    var ending: String?
    /// The actions queued this round, and whether each counts down.
    var queued: [(definition: any ActionDefinition, countsDown: Bool)] = []
    /// Set when a tool gave the model text to carry on from, like a read or an error.
    var carriesOn = false
  }

  /// How long a look begun on release stays fresh enough for a request to use.
  private static let preparedLifetime: Duration = .seconds(10)

  private var gateway: any ChatCompleting
  private let herdr: HerdrClient
  private let watcher: HerdrWatcher?
  private var configuration: Configuration
  /// Time since the session began, on the clock it was given.
  private let now: @Sendable () -> Duration
  /// Sleeps until a time since the session began, on the same clock.
  private let sleepUntil: @Sendable (Duration) async throws -> Void

  private var exchanges: [Exchange] = []
  /// When the last request that succeeded began, or the last alert fired:
  /// the conversation is remembered for `conversationWindow` after it.
  private var lastRequest: Duration?
  /// Each agent's status, by pane id, in the snapshot of the last request
  /// that succeeded; nil until the conversation's first one.
  private var lastStatuses: [String: String]?
  /// Bumped on every new conversation, so a request still running from the
  /// last one can't add to it.
  private var conversation = 0
  /// A look begun by `prepare()`, for the request about to come.
  private var prepared: (began: Duration, conversation: Int, look: Task<Look, any Error>)?
  private var actions: [String: (action: Action, status: ActionStatus)] = [:]
  private var notes: [String] = []
  private var actionCounter = 0
  /// The alerts set and not yet fired, by id. They outlive the conversation:
  /// only firing ends one.
  private var pendingAlerts: [String: Alert] = [:]
  private var alertCounter = 0
  /// Who follows the alerts as they fire.
  private var alertFollowers = Followers<Alert.Fired>()
  /// Follows the watcher's changes for the alerts and the agent list, from
  /// the first alert set or list follower, for as long as the session lives:
  /// the one session lasts the app.
  private var changeFollowing: Task<Void, Never>?
  /// The agent list as the last look found it, kept up with the watcher's
  /// changes while it stands.
  private var listed: [AgentList.Entry] = []
  /// Who follows the agent lists as requests read them.
  private var listFollowers = Followers<[AgentRow]>()
  /// Each agent's screen as the last request that succeeded saw it, to find
  /// what's new on it since. Never sent to the model again.
  private var shown: [String: String] = [:]

  /// The simple actions from one request, counting down together. Each
  /// request's actions get their own, so a later request never moves an
  /// earlier one's end. Pausing cancels `timer` and keeps `remaining`, for
  /// `resumeCountdown(_:)` to pick up from there.
  private struct Countdown {
    /// The actions counting down, in the order they were queued.
    var actions: [String]
    /// Whole seconds left.
    var remaining: Int
    /// Where its statuses go: the `onEvent` of the request that started it.
    var announce: @Sendable (AssistantEvent) -> Void
    /// Nil while paused.
    var timer: Task<Void, Never>?
  }
  /// The countdowns under way, by the number each was started with.
  private var countdowns: [Int: Countdown] = [:]
  private var countdownCounter = 0
  /// Actions whose countdowns `stopCountdowns(_:)` stopped. It's set from
  /// outside the actor, so it holds the moment the note closes, ahead of
  /// anything else the session has still to do.
  private nonisolated let stopped = Mutex<Set<String>>([])
  /// How many presses have paused the countdowns, and which of them holds
  /// them now. Set by `pauseCountdowns()` from outside the actor the moment
  /// the user presses the key to speak, so no countdown ticks or ends from
  /// then on, even before the session gets to pause it; lifted only by that
  /// press's `resumeCountdowns(_:)`.
  private nonisolated let pauses = Mutex(Pauses())
  private struct Pauses {
    var count = 0
    /// The pause holding the countdowns, if any: always the latest press's.
    var current: Int?
  }

  /// With a `watcher`, requests say how long each agent has been working or
  /// waiting, and what changed since the last request; without one they're
  /// read from snapshots alone.
  public init(
    gateway: any ChatCompleting, herdr: HerdrClient, watcher: HerdrWatcher? = nil, configuration: Configuration,
    clock: some Clock<Duration> = ContinuousClock()
  ) {
    self.gateway = gateway
    self.herdr = herdr
    self.watcher = watcher
    self.configuration = configuration
    let began = clock.now
    now = { began.duration(to: clock.now) }
    sleepUntil = { time in try await clock.sleep(until: began.advanced(by: time), tolerance: nil) }
  }

  /// Takes new settings for the requests to come and keeps the conversation:
  /// the model and effort, and a new gateway when the API key changed. A
  /// request already running finishes with what it started with.
  public func update(model: String, effort: String?, gateway: (any ChatCompleting)? = nil) {
    configuration.model = model
    configuration.effort = effort
    if let gateway { self.gateway = gateway }
  }

  /// Starts reading Herdr for a request about to come, so the snapshot and
  /// the agents' screens are ready by the time its transcript is: called on
  /// releasing the key. The next request uses them if it comes within
  /// `preparedLifetime`, and otherwise reads Herdr itself.
  public func prepare() {
    let began = now()
    endConversationIfStale(at: began)
    prepared = (began, conversation, Task { try await look() })
  }

  /// Runs one request through the tool loop. Follow-ups in the same
  /// conversation carry the last few exchanges as text, and read only the
  /// agents those were about plus any that changed; a request that fails
  /// leaves the conversation as it was. A round that only queues actions
  /// ends the turn, with their cards as the answer. An action queued as a
  /// correction replaces the earlier card it names, once the turn succeeds.
  /// With a `countdown`, a simple action (a send to an idle agent, or a start
  /// in a new tab) runs that long after the turn ends instead of waiting on
  /// its card, unless the user asked to see it first or cancels it, and
  /// `onEvent` keeps announcing its statuses until then (ADR 0001). A send or
  /// start that waits instead says why on its card. Without one, every
  /// action waits, and no card says why. `readAloud` is the user's Read
  /// Answers Aloud setting, which the model is told so it writes a spoken
  /// version of every answer while it's on (ADR 0002).
  public func ask(
    _ request: String, countdown: Duration? = nil, readAloud: Bool = false,
    onEvent: @escaping @Sendable (AssistantEvent) -> Void = { _ in }
  ) async throws -> AssistantTurn {
    let start = now()
    endConversationIfStale(at: start)
    let conversation = conversation
    let early = await takePrepared(at: start)
    let seen: Look
    if let early { seen = early } else { seen = try await look() }
    // The list stands until the request is answered or fails; the note
    // shows the answer, or its error, from then on.
    defer { listed = [] }
    let (state, recent) = (seen.state, seen.recent)
    let agents = state.agents
    if !recent.isEmpty { onEvent(.reading(agents.filter { recent[$0.paneId] != nil })) }
    let delivered = notes
    notes.removeAll()
    var messages: [ChatMessage] = [
      .user(
        AssistantPrompt.userTurn(
          request, agents: agents, workspaces: state.workspaces, recentOutput: recent,
          startedTabs: state.startedTabs, since: seen.picture?.since ?? [:],
          changes: seen.lastAsked.map { AssistantPrompt.Changes(since: $0, list: seen.picture?.changes ?? [], progress: seen.progress) },
          alerts: Set(pendingAlerts.values.map(\.paneId)), readAloud: readAloud, notes: delivered,
          now: seen.picture?.mark.date ?? Date()))
    ]
    var reply = ""

    var turn = AssistantTurn(
      request: request, answer: "", actions: [], spoken: nil, usage: ChatUsage(), requestIds: [], iterations: 0,
      elapsed: .zero, modelElapsed: .zero, herdrElapsed: now() - start, readElapsed: seen.elapsed,
      readOnRelease: early != nil, agentsRead: configuration.prefetchLines > 0 ? seen.read.count : 0,
      eventsLive: seen.picture?.isLive)
    turn.countdown = countdown.map { Int(max(1, $0.components.seconds)) }

    do {
      while true {
        turn.iterations += 1
        onEvent(.thinking(iteration: turn.iterations))
        // On the last allowed round, forbid tools so the model has to answer.
        let mayUseTools = turn.iterations < configuration.maxIterations
        let modelStart = now()
        let completion = try await gateway.complete(chatRequest(messages, toolChoice: mayUseTools ? nil : "none"))
        let modelTime = now() - modelStart
        turn.modelElapsed += modelTime
        turn.roundModelElapsed.append(modelTime)
        turn.usage = turn.usage + completion.usage
        if let id = completion.requestId { turn.requestIds.append(id) }
        messages.append(completion.message)

        guard mayUseTools, let calls = completion.message.toolCalls, !calls.isEmpty else {
          let content = completion.message.content ?? "_No answer came back (the reply may have hit the token limit). Try asking again._"
          reply = Self.answer(content, turn: &turn)
          break
        }
        var round = Round()
        for (call, text) in await runTools(calls, onEvent: onEvent, turn: &turn, round: &round) {
          messages.append(.tool(callId: call.id, text))
        }
        // A tool that ends the turn, like a jump that closes the note, leaves
        // nothing for the model to say.
        if let ending = round.ending {
          turn.answer = ending
          reply = ending
          break
        }
        // Nor does a round that only queued actions: their cards are the
        // answer, under anything the model wrote alongside them, and a card
        // is never spoken.
        if !round.queued.isEmpty, !round.carriesOn {
          let ready = round.queued.map { $0.countsDown ? $0.definition.underway : $0.definition.ready }.joined(separator: " ")
          let written = AssistantPrompt.splitSpoken(completion.message.content ?? "").note
          reply = Self.answer(written, otherwise: ready, turn: &turn)
          break
        }
      }
    } catch {
      // The notes this request carried go with the next one instead.
      notes = delivered + notes
      // The note shows no cards for a failed request, so nothing it queued
      // may be left waiting.
      withdraw(turn.actions.map(\.id), note: { definition, id, _ in definition.withdrawnNote(id) }, onEvent: onEvent)
      throw error
    }
    replace(turn.replacing, turn: &turn, onEvent: onEvent)
    // The cards are showing from here, so a countdown starts now.
    let counting = turn.actions.filter { $0.countdown != nil }.map(\.id)
    if let seconds = turn.countdown, !counting.isEmpty { startCountdown(counting, seconds: seconds, announce: onEvent) }

    turn.elapsed = now() - start
    if let mark = seen.picture?.mark { await watcher?.asked(mark) }
    shown = shown.filter { pane, _ in agents.contains { $0.paneId == pane } }.merging(seen.screens) { _, new in new }
    guard conversation == self.conversation else { return turn }
    exchanges.append(
      Exchange(
        request: AssistantPrompt.earlierExchange(request, notes: delivered, queued: turn.actions), answer: reply,
        about: turn.about))
    exchanges = Array(exchanges.suffix(configuration.rememberedExchanges))
    lastRequest = start
    lastStatuses = Dictionary(agents.map { ($0.paneId, $0.status) }, uniquingKeysWith: { first, _ in first })
    return turn
  }

  /// Runs a queued action: sends the message, starts the agent or closes the
  /// tab. Targets are checked again against a fresh Herdr snapshot, so an
  /// agent, workspace or tab that closed since the model saw it is never
  /// reached. Returns the agent messaged or started; nil for a closed tab.
  /// Only an action still waiting or counting down runs, the latter at once:
  /// confirming one that's busy, done, cancelled or failed does nothing, so
  /// an action never runs twice.
  @discardableResult
  public func confirm(_ actionId: String, onEvent: @escaping @Sendable (AssistantEvent) -> Void = { _ in }) async throws
    -> HerdrAgent?
  {
    guard let (action, status) = actions[actionId], status.isUndecided else { return nil }
    return try await perform(action, by: .confirmed, onEvent: onEvent)
  }

  /// Cancels an action still waiting or counting down, and tells the model.
  public func cancel(_ actionId: String, onEvent: @escaping @Sendable (AssistantEvent) -> Void = { _ in }) {
    guard let (action, status) = actions[actionId], status.isUndecided else { return }
    setStatus(actionId, .cancelled, onEvent: onEvent)
    notes.append(action.definition.cancelledNote(actionId, countingDown: status.isCountingDown))
  }

  /// Drops these actions unsent if they're still waiting or counting down,
  /// because the note showing their cards closed, and tells the model on its
  /// next turn.
  public func drop(_ actionIds: [String]) {
    withdraw(actionIds, note: { $0.droppedNote($1, countingDown: $2) }, onEvent: { _ in })
    stopped.withLock { $0.subtract(actionIds) }
  }

  /// Stops these actions' countdowns at once, wherever the session's other
  /// work stands, because the note showing their cards is closing: none of
  /// them runs after it has gone, even if the drop that follows is held up
  /// behind other calls. One whose countdown ends first is dropped there,
  /// with the same note. Waiting cards are left for the drop.
  public nonisolated func stopCountdowns(_ actionIds: [String]) {
    stopped.withLock { $0.formUnion(actionIds) }
  }

  /// Pauses every countdown under way, because the user is holding the key
  /// to speak: each card shows it paused, and holds the seconds it showed
  /// until `resumeCountdowns(_:)` with the pause this returns. It takes
  /// effect at once from outside the actor, so a countdown due to end before
  /// the session gets here holds too. A countdown already at its end, being
  /// checked against Herdr, still runs. A later press's pause takes over from
  /// this one, so only the later press's resume lifts it.
  public nonisolated func pauseCountdowns() -> CountdownPause {
    let pause = pauses.withLock { pauses in
      pauses.count += 1
      pauses.current = pauses.count
      return CountdownPause(number: pauses.count)
    }
    Task { await pauseAll() }
    return pause
  }

  /// Runs on every paused countdown from the seconds it was paused at, once
  /// the request the user spoke has been answered, failed or been dropped.
  /// A correction has replaced its action by then, so that one stays
  /// dropped. A countdown started during the pause, like the answer's own,
  /// counts until a tick finds the pause, and then holds and restarts here
  /// with the rest. Does nothing once a later press has paused them, since
  /// that press may be correcting them: its own resume lifts them.
  public func resumeCountdowns(_ pause: CountdownPause) {
    let lifted = pauses.withLock { pauses in
      guard pauses.current == pause.number else { return false }
      pauses.current = nil
      return true
    }
    guard lifted else { return }
    for (key, countdown) in countdowns where countdown.timer == nil {
      for id in countdown.actions where actions[id]?.status == .paused {
        setStatus(id, .countingDown(countdown.remaining), onEvent: countdown.announce)
      }
      resumeCountdown(key)
    }
  }

  /// Forgets the earlier exchanges and any notes not yet delivered, so the
  /// next request starts a fresh conversation. Any countdown still under way
  /// ends, its actions dropped unsent.
  public func newConversation() {
    let running = countdowns
    countdowns.removeAll()
    for countdown in running.values {
      countdown.timer?.cancel()
      for id in countdown.actions where isCountingDown(id) { setStatus(id, .withdrawn, onEvent: countdown.announce) }
    }
    exchanges.removeAll()
    notes.removeAll()
    lastRequest = nil
    lastStatuses = nil
    conversation += 1
  }

  /// Whether there's a conversation to carry on: one with earlier exchanges,
  /// the last of them within `conversationWindow`. One gone stale is
  /// forgotten now, as the next request would forget it.
  public func remembers() -> Bool {
    endConversationIfStale(at: now())
    return !exchanges.isEmpty
  }

  /// Each alert as it fires, from now on: the user asked to be told when an
  /// agent stops working, and it has. Shown as a quiet note; the model hears
  /// of it on the next request.
  public func alerts() -> AsyncStream<Alert.Fired> {
    alertFollowers.add { [weak self] id in Task { await self?.forgetAlertFollower(id) } }
  }

  /// Our own errors describe themselves for a person; anything else (URL
  /// errors, the Dictation API) falls back to the system's wording.
  nonisolated static func describe(_ error: any Error) -> String {
    switch error {
    case let error as HerdrError: error.description
    case let error as GatewayError: error.description
    case let error as CommandError: error.description
    default: error.localizedDescription
    }
  }

  // MARK: - Private

  /// Starts a fresh conversation when the last request came longer than
  /// `conversationWindow` before `time`.
  private func endConversationIfStale(at time: Duration) {
    if let lastRequest, time - lastRequest > configuration.conversationWindow { newConversation() }
  }

  /// The look `prepare()` began, if it's for this conversation and still
  /// fresh. One that failed is dropped, for the request to read Herdr itself.
  private func takePrepared(at start: Duration) async -> Look? {
    guard let prepared else { return nil }
    self.prepared = nil
    guard prepared.conversation == conversation, start - prepared.began <= Self.preparedLifetime else { return nil }
    return try? await prepared.look.value
  }

  /// A Herdr snapshot, the watcher's picture, and the screens of the agents
  /// the request reads up front. With a watcher, agents working all along
  /// since the last request are read too, for what's new on their screens.
  /// The agent list goes out as soon as the snapshot is in, before the reads.
  private func look() async throws -> Look {
    let began = now()
    let state = try await herdr.state()
    // "What changed since I last asked" starts at the last request that went
    // through, in any conversation, and even before Holler last relaunched.
    let lastAsked = await watcher?.lastAsked
    let picture = await watcher?.observe(state.agents, after: lastAsked)
    list(state.agents, since: picture?.since ?? [:], now: picture?.mark.date ?? Date())
    let changed = Set(picture?.changes.map(\.paneId) ?? [])
    let toRead = followUpReads(state.agents, changed: changed) ?? state.agents
    let stillWorking =
      picture == nil || lastAsked == nil
      ? [] : state.agents.filter { $0.status == "working" && !changed.contains($0.paneId) && shown[$0.paneId] != nil }
    let checked = stillWorking.filter { agent in !toRead.contains { $0.paneId == agent.paneId } }
    let screens = await recentOutput(of: toRead + checked)
    let full = Set(toRead.map(\.paneId))
    var progress: [String: [String]] = [:]
    for agent in stillWorking {
      guard let screen = screens[agent.paneId], let earlier = shown[agent.paneId] else { continue }
      progress[agent.paneId] = PaneText.newLines(since: earlier, in: screen)
    }
    return Look(
      state: state, read: toRead + checked, recent: screens.filter { full.contains($0.key) }, screens: screens,
      picture: picture, lastAsked: lastAsked?.date, progress: progress, elapsed: now() - began)
  }

  /// Puts the model's reply in the turn: the answer, with its <about> and
  /// <read_aloud> blocks taken out, or `fallback` when there's no answer.
  /// Returns the reply as later requests carry it.
  private static func answer(_ content: String, otherwise fallback: String = "", turn: inout AssistantTurn) -> String {
    let (rest, about) = AssistantPrompt.splitAbout(content)
    let (answer, spoken) = AssistantPrompt.splitSpoken(rest)
    turn.answer = answer.isEmpty ? fallback : answer
    turn.spoken = spoken
    turn.about += about
    return AssistantPrompt.rememberedReply(turn.answer, about: about, spoken: spoken)
  }

  /// Does what the action asks in Herdr, showing it busy and then done or
  /// failed, and leaves the model a note on how it went and what set it off.
  private func perform(
    _ action: Action, by trigger: ActionTrigger, onEvent: @Sendable (AssistantEvent) -> Void
  ) async throws -> HerdrAgent? {
    setStatus(action.id, .busy, onEvent: onEvent)
    do {
      let (agent, note) = try await action.definition.run(action.id, herdr: herdr, by: trigger)
      notes.append(note)
      setStatus(action.id, .done, onEvent: onEvent)
      return agent
    } catch {
      notes.append(action.definition.failedNote(action.id, error, by: trigger))
      setStatus(action.id, .failed(action.definition.failedReason(error)), onEvent: onEvent)
      throw error
    }
  }

  /// Drops these actions unsent if they're still waiting or counting down,
  /// and tells the model why on its next turn; `note` is also told whether
  /// the action was counting down.
  private func withdraw(
    _ actionIds: [String], note: (any ActionDefinition, String, Bool) -> String,
    onEvent: @Sendable (AssistantEvent) -> Void
  ) {
    for id in actionIds {
      guard let (action, status) = actions[id], status.isUndecided else { continue }
      setStatus(id, .withdrawn, onEvent: onEvent)
      notes.append(note(action.definition, id, status.isCountingDown))
    }
  }

  /// Records an action's new status and announces it. An action that stops
  /// counting down, however that came about, may leave its countdown with
  /// nothing to run, and then the countdown ends.
  private func setStatus(_ actionId: String, _ status: ActionStatus, onEvent: @Sendable (AssistantEvent) -> Void) {
    actions[actionId]?.status = status
    onEvent(.status(actionId: actionId, status))
    if !status.isCountingDown { endCountdownIfEmpty(holding: actionId) }
  }

  /// Which agents a follow-up reads up front: those the remembered exchanges
  /// were about, plus any whose status differs from the last request's
  /// snapshot or that weren't in it, or that the watcher saw `changed`, even
  /// if they've changed back. Nil on a conversation's first request, which
  /// reads every agent.
  private func followUpReads(_ agents: [HerdrAgent], changed: Set<String>) -> [HerdrAgent]? {
    guard let lastStatuses else { return nil }
    let focus = Set(exchanges.flatMap(\.about))
    return agents.filter {
      focus.contains($0.paneId) || changed.contains($0.paneId) || lastStatuses[$0.paneId] != $0.status
    }
  }

  /// What's on these agents' screens, read in parallel: only the screen,
  /// since reading back past it is many times slower. A pane that fails to
  /// read is simply left out; the model can still ask for it, or for more,
  /// with read_agents.
  private func recentOutput(of agents: [HerdrAgent]) async -> [String: String] {
    guard configuration.prefetchLines > 0 else { return [:] }
    let (herdr, lines, characters) = (herdr, configuration.prefetchLines, configuration.prefetchCharacters)
    return await withTaskGroup(of: (String, String?).self) { group in
      for agent in agents {
        group.addTask {
          (agent.paneId, try? await herdr.readScreen(agent, lines: lines, maxCharacters: characters))
        }
      }
      var outputs: [String: String] = [:]
      for await (paneId, text) in group where text?.isEmpty == false { outputs[paneId] = text }
      return outputs
    }
  }

  /// The system prompt, the earlier exchanges, then this request's messages so far.
  private func chatRequest(_ messages: [ChatMessage], toolChoice: String?) -> ChatRequest {
    let earlier = exchanges.flatMap { [ChatMessage.user($0.request), ChatMessage(role: .assistant, content: $0.answer)] }
    return ChatRequest(
      model: configuration.model,
      messages: [.system(AssistantPrompt.system, cached: true)] + earlier + messages,
      tools: AssistantTools.all.map(\.definition),
      toolChoice: toolChoice,
      maxTokens: configuration.maxTokens,
      temperature: configuration.temperature,
      effort: configuration.effort
    )
  }

  /// Runs a round of tool calls and applies each one's result, noting in
  /// `round` what it leaves the turn to do, and returns the text for the model
  /// in call order. Reads run concurrently, after every other tool has run on
  /// its own, in call order.
  private func runTools(
    _ calls: [ToolCall], onEvent: @escaping @Sendable (AssistantEvent) -> Void, turn: inout AssistantTurn,
    round: inout Round
  ) async -> [(ToolCall, String)] {
    let context = ToolContext(herdr: herdr, onEvent: onEvent)
    var results: [(ToolCall, String)] = []
    var reads: [(index: Int, tool: any AssistantTool, call: ToolCall)] = []
    var failed = Array(repeating: false, count: calls.count)
    for (index, call) in calls.enumerated() {
      results.append((call, ""))
      guard let tool = AssistantTools.named(call.function.name) else {
        failed[index] = true
        results[index].1 = apply(.error("unknown tool \(call.function.name)"), onEvent: onEvent, turn: &turn, round: &round).text
        continue
      }
      if tool.isRead {
        reads.append((index, tool, call))
      } else {
        let (result, threw) = await Self.invoke(tool, call, context)
        let applied = apply(result, onEvent: onEvent, turn: &turn, round: &round)
        (results[index].1, failed[index]) = (applied.text, threw || applied.failed)
      }
    }

    let readResults = await withTaskGroup(of: (Int, (result: ToolResult, failed: Bool)).self) { group in
      for (index, tool, call) in reads {
        group.addTask { (index, await Self.invoke(tool, call, context)) }
      }
      var collected: [(Int, (result: ToolResult, failed: Bool))] = []
      for await result in group { collected.append(result) }
      return collected
    }
    for (index, (result, threw)) in readResults.sorted(by: { $0.0 < $1.0 }) {
      let applied = apply(result, onEvent: onEvent, turn: &turn, round: &round)
      (results[index].1, failed[index]) = (applied.text, threw || applied.failed)
      if reads.first(where: { $0.index == index })?.tool.name == "read_agents" {
        turn.readProblems += threw ? ["read_agents failed: \(applied.text)"] : ReadAgentsTool.problems(in: applied.text)
      }
    }
    turn.tools += zip(calls, failed).map { ($0.function.name, $1) }
    return results
  }

  /// Does what a tool's result asks of the turn, returning the text for the
  /// model and whether the call failed here, like a card that can't be replaced.
  private func apply(
    _ result: ToolResult, onEvent: @escaping @Sendable (AssistantEvent) -> Void, turn: inout AssistantTurn,
    round: inout Round
  ) -> (text: String, failed: Bool) {
    switch result {
    case .text(let text, let about):
      turn.about += about
      round.carriesOn = true
      return (text, false)
    case .queued(let definition, let replacing, let showFirst):
      if let replacing, actions[replacing]?.status.isUndecided != true {
        let refused = apply(
          .error("\(replacing) is not a card still waiting, so it can't be replaced; nothing was queued"),
          onEvent: onEvent, turn: &turn, round: &round)
        return (refused.text, true)
      }
      turn.about += definition.about
      let (id, countsDown, result) = enqueue(definition, showFirst: showFirst, onEvent: onEvent, turn: &turn)
      round.queued.append((definition, countsDown))
      if let replacing { turn.replacing.append((replacing, id)) }
      return (result, false)
    case .endTurn(let answer, let result, let focused):
      turn.focused = focused
      turn.about += focused.map { [$0.paneId] } ?? []
      round.ending = answer
      return (result, false)
    case .alert(let agent):
      let refusal: String?
      if watcher == nil {
        refusal = "Holler isn't following Herdr's events here, so it can't tell the user later; nothing was set"
      } else if let set = pendingAlerts.values.first(where: { $0.paneId == agent.paneId }) {
        refusal = "\(set.id) is already set to tell the user when \(agent.paneId) stops working; nothing more was set"
      } else {
        refusal = nil
      }
      if let refusal { return (apply(.error(refusal), onEvent: onEvent, turn: &turn, round: &round).text, true) }
      alertCounter += 1
      let alert = Alert(
        id: "t\(alertCounter)", paneId: agent.paneId, name: "\(agent.workspace) / \(agent.tab)", request: turn.request)
      pendingAlerts[alert.id] = alert
      followChanges()
      turn.about.append(agent.paneId)
      round.carriesOn = true
      // With the stream down, the watcher sees a change only when it's back
      // or when a request takes a snapshot, so the model can say so.
      let events = turn.eventsLive == true ? "live" : "down"
      return (
        #"{"status":"will_tell_the_user","alert_id":"\#(alert.id)","agent_status":"\#(agent.status)","events":"\#(events)"}"#,
        false)
    }
  }

  /// The tool's result, and whether it threw, leaving the model its error.
  private static func invoke(_ tool: any AssistantTool, _ call: ToolCall, _ context: ToolContext) async
    -> (result: ToolResult, failed: Bool)
  {
    let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.function.arguments.utf8))) ?? .object([:])
    do {
      return (try await tool.run(arguments, context), false)
    } catch {
      return (.error("\(error)"), true)
    }
  }

  /// Queues the action as a card, returning its id, whether it counts down
  /// and the result for the model. It counts down when the request allows
  /// one, the action is simple, and the user didn't ask to see it first;
  /// otherwise it waits, and when the request allowed a countdown, a kind
  /// that might have counted down says why it didn't.
  private func enqueue(
    _ definition: any ActionDefinition, showFirst: Bool, onEvent: @escaping @Sendable (AssistantEvent) -> Void,
    turn: inout AssistantTurn
  ) -> (id: String, countsDown: Bool, result: String) {
    actionCounter += 1
    let id = "a\(actionCounter)"
    let action: Action
    switch (turn.countdown, definition.simplicity) {
    case (nil, _): action = Action(id: id, definition)
    case (_, .simple) where showFirst: action = Action(id: id, definition, waitsBecause: "You asked to see this first.")
    case (let seconds?, .simple): action = Action(id: id, definition, countdown: seconds)
    case (_, let simplicity): action = Action(id: id, definition, waitsBecause: simplicity.waitReason)
    }
    actions[id] = (action, action.firstStatus)
    turn.actions.append(action)
    onEvent(.queued(action))
    let status = action.countdown.map { "runs_in_\($0)s_unless_the_user_cancels" } ?? "awaiting_user_confirmation"
    return (id, action.countdown != nil, #"{"status":"\#(status)","action_id":"\#(id)"}"#)
  }

  /// Drops each earlier card a correction replaces, unsent, and tells the
  /// model. One the user confirmed or cancelled while the turn ran is left as
  /// it is, with the correction as a card of its own.
  private func replace(
    _ replacing: [(old: String, new: String)], turn: inout AssistantTurn, onEvent: @Sendable (AssistantEvent) -> Void
  ) {
    for (old, new) in replacing {
      guard let (action, status) = actions[old], status.isUndecided else {
        notes.append("\(new) was meant to replace \(old), but the user had already answered \(old); \(new) waits on its own.")
        continue
      }
      setStatus(old, .replaced, onEvent: onEvent)
      turn.replaced.append(old)
      notes.append(action.definition.replacedNote(old, by: new))
    }
  }

  // MARK: - Agent list

  /// The agent list, each time a request reads Herdr: on releasing the key,
  /// or with the request when nothing was read on release. While a list
  /// stands, until the request is answered or fails, each change the
  /// watcher reports gives an updated one, timed at the change: a row flips,
  /// one drops off, one joins; the last one closing gives an empty list.
  /// Lists only start once a follower is in, so follow before `prepare()`.
  public func agentLists() -> AsyncStream<[AgentRow]> {
    followChanges()
    return listFollowers.add { [weak self] id in Task { await self?.forgetListFollower(id) } }
  }

  private func forgetListFollower(_ id: UUID) {
    listFollowers.forget(id)
  }

  /// Gives the followers the list a look found.
  private func list(_ agents: [HerdrAgent], since: [String: HerdrWatcher.Since], now: Date) {
    listed = AgentList.entries(agents, since: since)
    listFollowers.yield(AgentList.rows(listed, now: now))
  }

  // MARK: - Alerts

  private func forgetAlertFollower(_ id: UUID) {
    alertFollowers.forget(id)
  }

  /// Starts following the watcher's changes, once, for the alerts to come
  /// and the agent list.
  private func followChanges() {
    guard changeFollowing == nil, let watcher else { return }
    changeFollowing = Task { [weak self] in
      for await change in await watcher.changes() { await self?.observe(change) }
    }
  }

  /// A change the watcher reported: it may fire an alert, and it keeps the
  /// agent list current while one stands.
  private func observe(_ change: HerdrWatcher.Change) {
    fireAlertIfDue(change)
    guard !listed.isEmpty else { return }
    listed = AgentList.applying(change, to: listed)
    listFollowers.yield(AgentList.rows(listed, now: change.at))
  }

  /// Fires the alert for this agent if the change is its agent stopping
  /// work: finishing, ending by needing the user, or closing. The note the
  /// model gets says what the user was told; a follow-up then carries on
  /// from the alert, even if the conversation had gone quiet.
  private func fireAlertIfDue(_ change: HerdrWatcher.Change) {
    guard let alert = pendingAlerts.values.first(where: { $0.paneId == change.paneId }),
      change.from == "working" || change.to == nil
    else { return }
    pendingAlerts[alert.id] = nil
    let what =
      switch change.to {
      case nil: "closed"
      case "blocked"?: "stopped and needs you"
      default: "finished"
      }
    let fired = Alert.Fired(alert: alert, answer: "**\(alert.name)** has \(what).")
    let time = now()
    endConversationIfStale(at: time)
    lastRequest = time
    let status = change.to.map { ", now \($0)" } ?? ""
    // "by" when a snapshot found it so, some time after it happened.
    let when = (change.exact ? "at " : "by ") + change.at.formatted(date: .omitted, time: .standard)
    notes.append(
      "Holler told the user in a note that \(alert.paneId) (\(alert.name)) had \(what) \(when)\(status), as they "
        + "asked (\(alert.id)); that alert is done.")
    alertFollowers.yield(fired)
  }

  // MARK: - Countdown

  /// Starts these actions, all from one request, counting down together from
  /// `seconds`. Any countdown already under way carries on as it was.
  private func startCountdown(_ ids: [String], seconds: Int, announce: @escaping @Sendable (AssistantEvent) -> Void) {
    countdownCounter += 1
    countdowns[countdownCounter] = Countdown(actions: ids, remaining: seconds, announce: announce, timer: nil)
    resumeCountdown(countdownCounter)
  }

  /// Runs a countdown on from where it stands: a tick each second, shown on
  /// each of its cards still counting, then its actions.
  private func resumeCountdown(_ key: Int) {
    guard let countdown = countdowns[key], countdown.timer == nil else { return }
    let (from, remaining, sleepUntil) = (now(), countdown.remaining, sleepUntil)
    countdowns[key]?.timer = Task {
      for left in stride(from: remaining - 1, through: 0, by: -1) {
        do { try await sleepUntil(from + .seconds(remaining - left)) } catch { return }
        // Cancelled while asleep: nothing is left counting, or it was paused.
        guard !Task.isCancelled else { return }
        // The user pressed the key while it slept: it holds where it stood.
        if self.isPaused {
          self.pauseCountdown(key)
          return
        }
        self.countdowns[key]?.remaining = left
        if left > 0 { self.showCountdown(key) }
      }
      await self.finishCountdown(key)
    }
  }

  /// Whether a press holds the countdowns paused.
  private nonisolated var isPaused: Bool { pauses.withLock { $0.current != nil } }

  /// Pauses every countdown under way, unless they have been resumed since
  /// the key was pressed.
  private func pauseAll() {
    guard isPaused else { return }
    for key in countdowns.keys { pauseCountdown(key) }
  }

  /// Stops a countdown's timer, keeping the seconds it shows, and shows each
  /// of its cards still counting as paused.
  private func pauseCountdown(_ key: Int) {
    guard let countdown = countdowns[key], let timer = countdown.timer else { return }
    timer.cancel()
    countdowns[key]?.timer = nil
    for id in countdown.actions where actions[id]?.status.isCountingDown == true {
      setStatus(id, .paused, onEvent: countdown.announce)
    }
  }

  /// Shows the seconds left on each of the countdown's cards still counting.
  private func showCountdown(_ key: Int) {
    guard let countdown = countdowns[key] else { return }
    for id in countdown.actions where isCountingDown(id) {
      setStatus(id, .countingDown(countdown.remaining), onEvent: countdown.announce)
    }
  }

  /// The end of a countdown: each action still counting is checked against a
  /// fresh snapshot, as on confirm, then run. One that no longer qualifies,
  /// because its agent has started working, got blocked or gone, its
  /// workspace has closed, or Herdr couldn't be read, waits on its card
  /// instead, which says why. One whose note has closed
  /// (`stopCountdowns(_:)`) is dropped unsent.
  private func finishCountdown(_ key: Int) async {
    guard let countdown = countdowns.removeValue(forKey: key) else { return }
    let due = countdown.actions.filter { isCountingDown($0) && !dropIfStopped($0, onEvent: countdown.announce) }
    guard !due.isEmpty else { return }
    let state: Result<HerdrState, any Error>
    do { state = .success(try await herdr.state()) } catch { state = .failure(error) }
    for id in due {
      // Run, cancelled or dropped while Herdr was read or an earlier one ran.
      guard let (action, status) = actions[id], status.isCountingDown, !dropIfStopped(id, onEvent: countdown.announce)
      else { continue }
      // Why it waits instead, for its card and for the model.
      let (reason, why): (String?, String)
      switch state.map(action.definition.simplicity(in:)) {
      case .success(.simple):
        _ = try? await perform(action, by: .countdownEnded, onEvent: countdown.announce)
        continue
      case .success(let simplicity):
        (reason, why) = (simplicity.waitReason, "it no longer qualified to run without a card")
      case .failure(let error):
        (reason, why) = ("Herdr couldn't be checked, so this waits for you.", "Herdr couldn't be read to check it again (\(error))")
      }
      setStatus(id, .waiting(because: reason), onEvent: countdown.announce)
      notes.append(
        "\(id)'s countdown ended, but \(why), so it waits for the user to confirm; nothing was done."
          + (reason.map { " Its card tells the user: \"\($0)\"" } ?? ""))
    }
  }

  /// Drops the action unsent, as closing its note would, if its countdown
  /// was stopped from outside; returns whether it was.
  private func dropIfStopped(_ id: String, onEvent: @Sendable (AssistantEvent) -> Void) -> Bool {
    guard stopped.withLock({ $0.contains(id) }) else { return false }
    withdraw([id], note: { $0.droppedNote($1, countingDown: $2) }, onEvent: onEvent)
    return true
  }

  /// Ends the countdown holding this action once none of its actions is
  /// still counting, so its timer doesn't run on to an end with nothing to do.
  private func endCountdownIfEmpty(holding id: String) {
    guard let (key, countdown) = countdowns.first(where: { $0.value.actions.contains(id) }),
      !countdown.actions.contains(where: isCountingDown)
    else { return }
    countdown.timer?.cancel()
    countdowns[key] = nil
  }

  private func isCountingDown(_ id: String) -> Bool {
    actions[id]?.status.isCountingDown ?? false
  }
}
