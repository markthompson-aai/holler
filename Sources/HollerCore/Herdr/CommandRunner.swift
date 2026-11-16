import Foundation
import Synchronization

public struct CommandResult: Sendable, Equatable {
  public let exitCode: Int32
  public let stdout: String
  public let stderr: String

  public init(exitCode: Int32, stdout: String, stderr: String) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
  }
}

/// Runs an executable with a literal argv. There is deliberately no way to
/// pass a shell string: every argument reaches the child as one opaque
/// element, so text from the model or the microphone can never be parsed
/// as shell syntax.
public protocol CommandRunning: Sendable {
  func run(_ executable: URL, _ arguments: [String], timeout: Duration) async throws -> CommandResult
}

public enum CommandError: Error, Equatable, CustomStringConvertible {
  case launchFailed(String)
  case timedOut(String)

  public var description: String {
    switch self {
    case .launchFailed(let detail): "could not launch: \(detail)"
    case .timedOut(let command): "\(command) timed out"
    }
  }
}

public struct ProcessRunner: CommandRunning {
  /// How long a command that has timed out gets to end on its own before
  /// it's killed outright.
  static let killGrace: Duration = .seconds(1)

  public init() {}

  public func run(_ executable: URL, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
    try await withCheckedThrowingContinuation { continuation in
      // Process I/O blocks, so keep it off the cooperative thread pool.
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try Self.runBlocking(executable, arguments, timeout: timeout) })
      }
    }
  }

  private static func runBlocking(_ executable: URL, _ arguments: [String], timeout: Duration) throws -> CommandResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err

    do {
      try process.run()
    } catch {
      throw CommandError.launchFailed("\(executable.path): \(error.localizedDescription)")
    }

    let timedOut = TimeoutFlag()
    let watchdog = DispatchWorkItem {
      guard process.isRunning else { return }
      timedOut.set()
      process.terminate()
      // One that ignores the request would keep the read below waiting for
      // good, and the request with it.
      DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace.timeInterval) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval, execute: watchdog)

    // stdout is drained before stderr. herdr's stderr is a short error line, so
    // it can't fill its pipe buffer and stall the child while we read stdout.
    let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
    let stderrData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()

    if timedOut.isSet {
      throw CommandError.timedOut(([executable.lastPathComponent] + arguments.prefix(2)).joined(separator: " "))
    }
    return CommandResult(
      exitCode: process.terminationStatus,
      stdout: String(decoding: stdoutData, as: UTF8.self),
      stderr: String(decoding: stderrData, as: UTF8.self)
    )
  }
}

private final class TimeoutFlag: Sendable {
  private let value = Atomic(false)

  func set() { value.store(true, ordering: .sequentiallyConsistent) }
  var isSet: Bool { value.load(ordering: .sequentiallyConsistent) }
}

extension Duration {
  var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
