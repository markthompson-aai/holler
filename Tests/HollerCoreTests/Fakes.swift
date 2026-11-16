import Foundation

@testable import HollerCore

/// Records every herdr invocation and answers from canned output.
final class FakeRunner: CommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var _calls: [[String]] = []
  var snapshot: String
  var readOutput: String
  var promptResult = CommandResult(exitCode: 0, stdout: "{}", stderr: "")
  /// Panes that answer a `recent-unwrapped` read the way Herdr does for a working agent.
  var workingPanes: Set<String> = []
  /// Panes whose `recent-unwrapped` read never finishes, so the runner times it out.
  var slowPanes: Set<String> = []
  private var _timeouts: [Duration] = []
  /// The timeout each call was given, in call order.
  var timeouts: [Duration] { lock.withLock { _timeouts } }
  var tabCreateResult = CommandResult(exitCode: 0, stdout: Fixtures.tabCreated, stderr: "")
  /// Answers for successive `agent start` calls; once used up, starts succeed.
  var agentStartResults: [CommandResult] = []
  /// Overrides `worktree list`, which otherwise answers that `--cwd` is the
  /// root of a repository with no other worktrees.
  var worktreeListResult: CommandResult?
  /// Overrides `worktree create`, which otherwise opens workspace w3 with the
  /// `--label`, its pane w3:p1 and the checkout at `--path`.
  var worktreeCreateResult: CommandResult?
  /// While set, each `agent prompt` is recorded and then waits here until the
  /// test opens it, like a Herdr slow to deliver a message.
  var promptGate: Gate?

  init(snapshot: String = Fixtures.snapshot, readOutput: String = "Tests passed.\n") {
    self.snapshot = snapshot
    self.readOutput = readOutput
  }

  var calls: [[String]] { lock.withLock { _calls } }
  var prompts: [[String]] { calls.filter { $0.starts(with: ["agent", "prompt"]) } }
  /// The pane of every `agent read`, in order.
  var reads: [String] { calls.filter { $0.starts(with: ["agent", "read"]) }.map { $0[2] } }
  /// Every call that changes Herdr, as opposed to reading it.
  var writes: [[String]] {
    calls.filter { call in [["api", "snapshot"], ["agent", "read"], ["worktree", "list"]].allSatisfy { !call.starts(with: $0) } }
  }

  func run(_ executable: URL, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
    lock.withLock {
      _calls.append(arguments)
      _timeouts.append(timeout)
    }
    switch Array(arguments.prefix(2)) {
    case ["api", "snapshot"]: return CommandResult(exitCode: 0, stdout: snapshot, stderr: "")
    case ["agent", "read"]:
      if slowPanes.contains(arguments[2]), arguments.contains("recent-unwrapped") {
        throw CommandError.timedOut("herdr agent read")
      }
      if workingPanes.contains(arguments[2]), arguments.contains("recent-unwrapped") {
        let error = #"{"error":{"code":"agent_not_idle","message":"use --source visible"}}"#
        return CommandResult(exitCode: 1, stdout: error, stderr: "")
      }
      return CommandResult(exitCode: 0, stdout: readOutput, stderr: "")
    case ["agent", "prompt"]:
      await promptGate?.wait()
      return promptResult
    case ["agent", "focus"]: return CommandResult(exitCode: 0, stdout: "{}", stderr: "")
    case ["agent", "send-keys"]: return CommandResult(exitCode: 0, stdout: "{}", stderr: "")
    case ["tab", "create"]: return tabCreateResult
    case ["tab", "close"]: return CommandResult(exitCode: 0, stdout: "{}", stderr: "")
    case ["workspace", "close"]: return CommandResult(exitCode: 0, stdout: "{}", stderr: "")
    case ["worktree", "list"]:
      return worktreeListResult ?? Fixtures.result([
        "type": "worktree_list", "worktrees": [],
        "source": [
          "repo_key": "k", "repo_name": URL(fileURLWithPath: Self.option("--cwd", arguments)).lastPathComponent,
          "repo_root": Self.option("--cwd", arguments), "source_checkout_path": Self.option("--cwd", arguments),
        ],
      ])
    case ["worktree", "create"]:
      return worktreeCreateResult ?? Fixtures.result([
        "type": "worktree_created",
        "workspace": ["workspace_id": "w3", "label": Self.option("--label", arguments)],
        "tab": ["tab_id": "w3:t1", "workspace_id": "w3", "label": "1"],
        "root_pane": ["pane_id": "w3:p1", "tab_id": "w3:t1", "workspace_id": "w3"],
        "worktree": [
          "path": Self.option("--path", arguments), "branch": Self.option("--branch", arguments), "label": "x",
          "is_bare": false, "is_detached": false, "is_prunable": false, "is_linked_worktree": true,
        ],
      ])
    case ["agent", "start"]:
      return lock.withLock { agentStartResults.isEmpty ? nil : agentStartResults.removeFirst() }
        ?? CommandResult(exitCode: 0, stdout: #"{"result":{"type":"agent_started"}}"#, stderr: "")
    default: return CommandResult(exitCode: 2, stdout: "", stderr: "unexpected \(arguments)")
    }
  }

  private static func option(_ name: String, _ arguments: [String]) -> String {
    arguments.firstIndex(of: name).map { arguments[$0 + 1] } ?? ""
  }
}

/// Holds back whoever waits on it until the test opens it.
final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let open = lock.withLock {
        if !isOpen { waiters.append(continuation) }
        return isOpen
      }
      if open { continuation.resume() }
    }
  }

  func open() {
    let waiting = lock.withLock {
      isOpen = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in waiting { waiter.resume() }
  }
}

/// Replays scripted completions and records the requests it received.
final class FakeGateway: ChatCompleting, @unchecked Sendable {
  static let failure = GatewayError.http(status: 500, body: "")

  private let lock = NSLock()
  private var script: [ChatMessage]
  private var _requests: [ChatRequest] = []
  /// Requests (counting from 1) that fail with `failure` instead of taking the
  /// next scripted completion.
  private let failing: Set<Int>

  init(_ script: [ChatMessage], failing: Set<Int> = []) {
    self.script = script
    self.failing = failing
  }

  var requests: [ChatRequest] { lock.withLock { _requests } }

  /// The request the model was last sent: the user turn with the agent list,
  /// settings and output.
  var lastUserRequest: String {
    requests.last?.messages.last { $0.role == .user }?.content ?? ""
  }

  func complete(_ request: ChatRequest) async throws -> ChatCompletion {
    let message: ChatMessage? = lock.withLock {
      _requests.append(request)
      if failing.contains(_requests.count) { return nil }
      return script.isEmpty ? ChatMessage(role: .assistant, content: "(script exhausted)") : script.removeFirst()
    }
    guard let message else { throw Self.failure }
    return ChatCompletion(message: message, usage: ChatUsage(inputTokens: 10, outputTokens: 5), requestId: "req")
  }
}

/// Records the events a session emits, in order.
final class Events: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [AssistantEvent] = []

  func append(_ event: AssistantEvent) { lock.withLock { events.append(event) } }

  var kinds: [String] {
    lock.withLock { events }.map {
      switch $0 {
      case .thinking: "thinking"
      case .reading: "reading"
      case .queued: "queued"
      case .status: "status"
      }
    }
  }

  /// Every action the session queued, in order.
  var queued: [Action] {
    lock.withLock { events }.compactMap {
      guard case .queued(let action) = $0 else { return nil }
      return action
    }
  }

  /// Every status the session announced for one action, in order.
  func statuses(of actionId: String) -> [ActionStatus] {
    lock.withLock { events }.compactMap {
      guard case .status(let id, let status) = $0, id == actionId else { return nil }
      return status
    }
  }
}

enum Fixtures {
  static let herdr = HerdrClient(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: FakeRunner())

  /// New worktrees go in `worktrees`, by default a folder that doesn't exist yet.
  static func client(
    _ runner: FakeRunner, excluding: [String] = [], workspaces: [String] = [],
    worktrees: String = FileManager.default.temporaryDirectory.appendingPathComponent("holler-worktrees-\(UUID().uuidString)").path
  ) -> HerdrClient {
    HerdrClient(
      executable: URL(fileURLWithPath: "/usr/bin/false"), runner: runner,
      filter: AgentFilter(excludedPathPrefixes: excluding, workspaces: workspaces), worktreesDirectory: worktrees)
  }

  /// A successful Herdr answer with `result`.
  static func result(_ result: [String: Any]) -> CommandResult {
    let data = try! JSONSerialization.data(withJSONObject: ["id": "cli", "result": result])
    return CommandResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
  }

  static func toolCall(_ id: String, _ name: String, _ arguments: String) -> ChatMessage {
    ChatMessage(role: .assistant, content: nil, toolCalls: [ToolCall(id: id, name: name, arguments: arguments)])
  }

  static func answer(_ text: String) -> ChatMessage {
    ChatMessage(role: .assistant, content: text)
  }

  static let demoAgent = HerdrAgent(
    paneId: "w1:p1", kind: "claude", status: "idle", workspace: "demo", tab: "main", tabId: "w1:t1",
    cwd: "/Users/test/Projects/demo", title: "Refactor parser", focused: false)

  /// A fresh, empty folder that really exists, for starting agents in.
  static func folder(_ name: String = "project") throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("holler-tests-\(UUID().uuidString)").appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func herdrError(_ code: String, _ message: String = "") -> CommandResult {
    CommandResult(exitCode: 1, stdout: #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#, stderr: "")
  }

  /// The fixture snapshot with the demo agent (w1:p1), idle there, given another status.
  static func snapshot(demoAgent status: String) -> String {
    snapshot.replacingOccurrences(of: #""agent_status":"idle""#, with: #""agent_status":"\#(status)""#)
  }

  /// The fixture snapshot after the demo agent (w1:p1) has gone.
  static let snapshotWithoutDemoAgent = snapshot.replacingOccurrences(
    of: #""pane_id":"w1:p1","tab_id""#, with: #""pane_id":"w1:p7","tab_id""#)

  static let tabCreated = """
    {"id":"cli:tab:create","result":{"root_pane":{"pane_id":"w1:p9","tab_id":"w1:t9","workspace_id":"w1"},
     "tab":{"label":"tests","tab_id":"w1:t9","workspace_id":"w1"},"type":"tab_created"}}
    """

  /// The fixture snapshot's agents, as written in it, so a test can replace them.
  static let snapshotAgents = """
    "agents":[
        {"agent":"claude","agent_status":"idle","cwd":"/Users/test/Projects/demo","focused":false,
         "pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_title_stripped":"Refactor parser",
         "revision":3,"future_field":{"nested":true}},
        {"agent":"codex","agent_status":"blocked","cwd":"/Users/test/Clients/acme","focused":true,
         "pane_id":"w2:p1","tab_id":"w2:t3","workspace_id":"w2","terminal_title_stripped":"Fix flaky test"}
      ]
    """

  static let snapshot = """
    {"id":"cli:api:snapshot","result":{"type":"snapshot","snapshot":{
      "protocol":22,"version":"0.9.3","focused_pane_id":"w2:p1",
      \(snapshotAgents),
      "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"main"},
              {"tab_id":"w1:t2","workspace_id":"w1","label":"notes"},
              {"tab_id":"w2:t3","workspace_id":"w2","label":"tests"}],
      "workspaces":[{"workspace_id":"w1","label":"demo"},{"workspace_id":"w2","label":"acme"}],
      "panes":[{"pane_id":"w1:p1","workspace_id":"w1","cwd":"/Users/test/Projects/demo"},
               {"pane_id":"w1:p2","workspace_id":"w1","cwd":"/Users/test/Projects/demo/docs"},
               {"pane_id":"w2:p1","workspace_id":"w2","cwd":"/Users/test/Clients/acme"}],
      "layouts":[]
    }}}
    """
}

/// Every value a stream has given so far, in order.
final class Collected<Element: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var _values: [Element] = []

  var values: [Element] { lock.withLock { _values } }

  init(_ stream: AsyncStream<Element>) {
    Task { for await value in stream { lock.withLock { _values.append(value) } } }
  }
}

/// Polls until `condition` holds, for work a session runs in its own tasks,
/// like a countdown's ticks after the clock moves.
func eventually(_ condition: () -> Bool) async {
  for _ in 0..<200 where !condition() {
    try? await Task.sleep(for: .milliseconds(5))
  }
}

/// Replays a script like `FakeGateway`, but answers only once the test
/// lets each request through, so a test can look at the note while the
/// model is thinking without racing a timer.
final class HeldGateway: ChatCompleting, @unchecked Sendable {
  let script: FakeGateway
  private let lock = NSLock()
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var permits = 0

  init(_ script: [ChatMessage], failing: Set<Int> = []) { self.script = FakeGateway(script, failing: failing) }

  /// How many requests wait to be let through.
  var held: Int { lock.withLock { waiting.count } }

  func complete(_ request: ChatRequest) async throws -> ChatCompletion {
    await withCheckedContinuation { continuation in
      lock.withLock {
        if permits > 0 {
          permits -= 1
          continuation.resume()
        } else {
          waiting.append(continuation)
        }
      }
    }
    return try await script.complete(request)
  }

  /// Lets one request through: the one waiting, or the next to come.
  func release() {
    let next: CheckedContinuation<Void, Never>? = lock.withLock {
      if waiting.isEmpty {
        permits += 1
        return nil
      }
      return waiting.removeFirst()
    }
    next?.resume()
  }
}

/// Polls until `condition` holds, for work the controller runs in its own tasks.
@MainActor func settled(_ condition: () -> Bool) async {
  for _ in 0..<200 where !condition() {
    try? await Task.sleep(for: .milliseconds(5))
  }
}

/// A clock that only moves when a test moves it. A sleep on it waits until
/// `advance(by:)` reaches its deadline, so a countdown ticks only as the test
/// lets it, and never runs on its own.
final class TestClock: Clock, @unchecked Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration
    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Sleeper {
    let id: UUID
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let lock = NSLock()
  private var _now = Instant(offset: .zero)
  private var sleepers: [Sleeper] = []

  var now: Instant { lock.withLock { _now } }
  /// How many sleeps wait for the clock to move: a countdown's timer still
  /// running shows up here.
  var sleeping: Int { lock.withLock { sleepers.count } }
  var minimumResolution: Duration { .zero }

  /// Moves time on, waking every sleep whose deadline has come.
  func advance(by duration: Duration) {
    let due: [Sleeper] = lock.withLock {
      _now = _now.advanced(by: duration)
      let due = sleepers.filter { $0.deadline <= _now }
      sleepers.removeAll { $0.deadline <= _now }
      return due
    }
    for sleeper in due { sleeper.continuation.resume() }
  }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let outcome: Result<Bool, any Error> = lock.withLock {
          if Task.isCancelled { return .failure(CancellationError()) }
          if deadline <= _now { return .success(true) }
          sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          return .success(false)
        }
        switch outcome {
        case .success(true): continuation.resume()
        case .success(false): break
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      let cancelled: Sleeper? = lock.withLock {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return sleepers.remove(at: index)
      }
      cancelled?.continuation.resume(throwing: CancellationError())
    }
  }
}
