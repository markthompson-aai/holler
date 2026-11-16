import Foundation
import HollerCore
import HollerSpeech

// Terminal front end over HollerCore: the same assistant loop the app
// uses, with typed requests instead of speech.

let usage = """
  usage:
    holler agents                          list agents Herdr can see
    holler read <pane-id> [--lines N]      print an agent's cleaned output
    holler ask "<request>" [--model M] [--dry-run]
    holler chat [--model M] [--dry-run]    multi-turn, one request per line
    holler bench "<request>" [--models a,b] [--efforts low,default] [--runs N]
    holler transcribe <audio-file>         speech to text via the Dictation API
    holler listen [--ask] [--dry-run]      record from the mic until Enter
    holler watch [--seconds N]             follow Herdr's events and print each change
    holler stats [--last N | --since 7d]   where the time went, from the app's turn log
  """

struct Options {
  var positional: [String] = []
  var flags: [String: String] = [:]

  init(_ arguments: ArraySlice<String>) {
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      if argument.hasPrefix("--") {
        let name = String(argument.dropFirst(2))
        flags[name] = ["dry-run", "ask"].contains(name) ? "true" : (iterator.next() ?? "")
      } else {
        positional.append(argument)
      }
    }
  }
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(1)
}

func status(_ message: String) {
  FileHandle.standardError.write(Data("\u{1B}[2m\(message)\u{1B}[0m\n".utf8))
}

SpeechInput.configureEngine()
// The nearest .env at or above the current folder, else the app's ~/.config/holler/.env.
let settings = Settings.load(
  dotEnv: DotEnv.find(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    ?? URL(fileURLWithPath: NSHomeDirectory() + "/.config/holler/.env"))
for problem in settings.problems { status(problem) }
/// Herdr, for the commands that need it. `stats` and `transcribe` run without.
let installedHerdr = settings.herdrPath.map { HerdrClient(executable: $0, filter: settings.filter) }
func requireHerdr() -> HerdrClient {
  guard let installedHerdr else { fail("herdr not found: install it from https://herdr.dev, or set HERDR_PATH") }
  return installedHerdr
}

/// The AssemblyAI key, for the commands that need it.
func requireKey() -> String {
  guard let apiKey = settings.apiKey else {
    fail("ASSEMBLYAI_API_KEY is not set: export it, or add it to a .env file (see .env.example)")
  }
  return apiKey
}

func makeSession(model: String, effort: String? = settings.effort) -> AssistantSession {
  let apiKey = requireKey()
  return AssistantSession(
    gateway: LLMGateway(apiKey: apiKey), herdr: requireHerdr(), configuration: .init(model: model, effort: effort))
}

func makeSpeech() -> SpeechInput {
  SpeechInput(apiKey: requireKey())
}

/// Transcribes `frames`, biased toward the names of the agents running now.
func transcribe(_ frames: AsyncStream<Data>, speech: SpeechInput) async throws -> String {
  let keyTerms = SpeechHints.keyTerms(for: (try? await installedHerdr?.agents()) ?? [])
  let clock = ContinuousClock()
  let start = clock.now
  let text = try await speech.transcribe(frames, keyTerms: keyTerms)
  status("transcribed in \((clock.now - start).seconds) · key terms: \(keyTerms.joined(separator: ", "))")
  return text
}

func describe(_ agent: HerdrAgent) -> String {
  "\(agent.workspace) / \(agent.tab) (\(agent.paneId))"
}

/// A waiting action in the words of its confirm card.
func describe(_ card: ConfirmCard) -> String {
  let lines =
    ["\(card.verb) \(card.target)"] + [card.subtitle, card.body.map { "\"\($0)\"" } ?? card.placeholder].compactMap { $0 }
    + card.details.map { "\($0.label): \($0.text ?? $0.placeholder ?? "")" } + card.warnings.map { "⚠ \($0)" }
  return lines.joined(separator: "\n    ")
}

func printTurn(_ turn: AssistantTurn, model: String) {
  print("\n" + turn.answer + "\n")
  if let spoken = turn.spoken { print("🔊 \(spoken)\n") }
  for action in turn.actions {
    print("→ waiting \(action.id): \(describe(action.card))")
  }
  for problem in turn.readProblems { status("read \(problem)") }
  let cached = turn.usage.cachedTokens > 0 ? ", \(turn.usage.cachedTokens) cached" : ""
  status(
    "\(model) · \(turn.elapsed.seconds) total, \(turn.modelElapsed.seconds) model · "
      + "\(turn.iterations) rounds · \(turn.usage.inputTokens) in / \(turn.usage.outputTokens) out\(cached)"
      + " · request \(turn.requestIds.last ?? "-")")
}

/// Asks before running each queued action, in its card's words. Without a
/// terminal to answer on, or with --dry-run, nothing is run.
func confirmActions(_ turn: AssistantTurn, session: AssistantSession, dryRun: Bool) async {
  for action in turn.actions {
    let words = action.card.words
    guard !dryRun, isatty(STDIN_FILENO) != 0 else {
      await session.cancel(action.id)
      status("\(dryRun ? "--dry-run" : "no terminal"): \(words.cancelled)")
      continue
    }
    print("\(words.button) \(action.id)? [y/N] ", terminator: "")
    if readLine()?.lowercased() == "y" {
      do {
        let agent = try await session.confirm(action.id) { event in
          if case .status(_, .failed(let reason)) = event { print("✗ \(words.failed): \(reason)") }
        }
        print("✓ \(words.done)" + (agent.map { ": \(describe($0))" } ?? ""))
      } catch {
        // Printed as it failed, with the reason.
      }
    } else {
      await session.cancel(action.id)
      print(words.cancelled)
    }
  }
}

func onEvent(_ event: AssistantEvent) {
  switch event {
  case .thinking(let iteration): status(iteration == 1 ? "thinking…" : "thinking… (round \(iteration))")
  case .reading(let agents): status("read " + agents.map(describe).joined(separator: ", "))
  case .queued(let action): status("queued \(action.id)")
  case .status(let id, .withdrawn): status("dropped \(id)")
  case .status(let id, .replaced): status("replaced \(id)")
  case .status: break
  }
}

extension Duration {
  var seconds: String {
    let (whole, atto) = components
    return String(format: "%.2fs", Double(whole) + Double(atto) / 1e18)
  }
}

let arguments = CommandLine.arguments
// Asking for help isn't an error: the usage goes to stdout and exits 0.
if arguments.count < 2 || ["help", "-h", "--help"].contains(arguments[1]) {
  print(usage)
  exit(arguments.count < 2 ? 1 : 0)
}
let options = Options(arguments.dropFirst(2))
let model = options.flags["model"] ?? settings.model
let dryRun = options.flags["dry-run"] != nil

do {
  switch arguments[1] {
  case "agents":
    let agents = try await requireHerdr().agents()
    if agents.isEmpty { print("no agents") }
    for agent in agents {
      print("\(agent.paneId)\t\(agent.status)\t\(agent.workspace) / \(agent.tab)\t\(agent.title)")
    }

  case "read":
    guard let paneId = options.positional.first else { fail(usage) }
    let lines = options.flags["lines"].flatMap(Int.init) ?? 150
    print(try await requireHerdr().read(paneId: paneId, lines: lines).text)

  case "ask":
    guard let request = options.positional.first else { fail(usage) }
    let session = makeSession(model: model)
    let turn = try await session.ask(request, onEvent: onEvent)
    printTurn(turn, model: model)
    await confirmActions(turn, session: session, dryRun: dryRun)

  case "chat":
    let session = makeSession(model: model)
    print("Ask about your agents. Empty line to quit.")
    while true {
      print("› ", terminator: "")
      guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
      do {
        let turn = try await session.ask(line, onEvent: onEvent)
        printTurn(turn, model: model)
        await confirmActions(turn, session: session, dryRun: dryRun)
      } catch {
        print("✗ \(error)")
      }
    }

  case "transcribe":
    guard let path = options.positional.first else { fail(usage) }
    let frames = try SpeechInput.frames(fromFile: URL(fileURLWithPath: path))
    print(try await transcribe(frames, speech: makeSpeech()))

  case "listen":
    let speech = makeSpeech()
    let microphone = Microphone()
    await speech.warmUp()
    let frames = try await microphone.start()
    // Transcription starts now, so audio uploads while you are still talking.
    let transcript = Task { try await transcribe(frames, speech: speech) }
    status("listening… press Enter to stop")
    _ = readLine()
    // As in the app, Herdr is read while the transcript comes in.
    let session = makeSession(model: model)
    if options.flags["ask"] != nil { await session.prepare() }
    let captured = try await microphone.stop()
    status("captured \(captured.seconds) of audio")
    let text = try await transcript.value
    print("“\(text)”")
    if options.flags["ask"] != nil, !text.isEmpty {
      let turn = try await session.ask(text, onEvent: onEvent)
      printTurn(turn, model: model)
      await confirmActions(turn, session: session, dryRun: dryRun)
    }

  case "bench":
    guard let request = options.positional.first else { fail(usage) }
    let runs = options.flags["runs"].flatMap(Int.init) ?? 1
    guard runs >= 1 else { fail("--runs takes a number of runs, 1 or more") }
    let models = options.flags["models"].map { $0.split(separator: ",").map(String.init) } ?? [model]
    // "default" sends no effort, leaving the model's own.
    let efforts = options.flags["efforts"].map { $0.split(separator: ",").map(String.init) } ?? [settings.effort ?? "default"]
    for model in models {
      for effort in efforts {
        for run in 1...runs {
          status("── \(model) effort \(effort) run \(run)")
          // A fresh session per run; queued actions are dropped, never sent.
          let turn = try await makeSession(model: model, effort: effort == "default" ? nil : effort).ask(request)
          printTurn(turn, model: model)
        }
      }
    }

  case "watch":
    // What the app's watcher sees: "exact" changes came from Herdr's events,
    // the rest from the snapshot taken every few seconds. It keeps no history
    // file: the app's is the app's to write, and this one starts fresh.
    let watcher = HerdrWatcher(herdr: requireHerdr(), source: HerdrSocket.locate())
    await watcher.start()
    let end = options.flags["seconds"].flatMap(Double.init).map { Date() + $0 }
    var mark: HerdrWatcher.Mark?
    var wasLive: Bool?
    while end.map({ Date() < $0 }) ?? true {
      let picture = await watcher.observe(try await requireHerdr().agents(), after: mark)
      if picture.isLive != wasLive { status(picture.isLive ? "events: live" : "events: down") }
      wasLive = picture.isLive
      for change in picture.changes {
        let time = change.at.formatted(date: .omitted, time: .standard)
        print("\(time)\t\(change.paneId)\t\(change.name)\t\(change.from ?? "new") → \(change.to ?? "closed")\t\(change.exact ? "exact" : "noticed")")
      }
      mark = picture.mark
      try await Task.sleep(for: .seconds(3))
    }
    await watcher.stop()

  case "stats":
    // The app logs one line per request to the unified log, at notice level
    // so macOS keeps it; /usr/bin/log reads them back. --since hands its
    // window to `log show --last`; --last N reads the whole store and keeps
    // the newest N turns. Neither means the last 7 days.
    let since = options.flags["since"]
    let newest = options.flags["last"]
    if since != nil, newest != nil { fail("use --last or --since, not both") }
    if let since, TurnLog.window(since) == nil { fail("--since takes a window like 7d, 24h or 30m") }
    var count: Int?
    if let newest {
      guard let turns = Int(newest), turns > 0 else { fail("--last takes a number of turns") }
      count = turns
    }
    let window = newest == nil ? (since ?? "7d") : nil
    let log = Process()
    log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    log.arguments =
      ["show", "--style", "compact", "--predicate", "subsystem == \"com.assemblyai.holler\" AND category == \"Turn\""]
      + (window.map { ["--last", $0] } ?? [])
    let pipe = Pipe()
    log.standardOutput = pipe
    try log.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    log.waitUntilExit()
    guard log.terminationStatus == 0 else { fail("log show exited with status \(log.terminationStatus)") }
    var records = TurnLog.records(in: String(decoding: output, as: UTF8.self))
    if let count { records = Array(records.suffix(count)) }
    print(TurnStats(records).table(window: window))

  default:
    fail(usage)
  }
} catch {
  fail("\(error)")
}
