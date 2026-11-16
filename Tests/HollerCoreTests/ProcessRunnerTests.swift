import Foundation
import Testing

@testable import HollerCore

/// The real runner, against /bin/sh rather than herdr.
@Suite struct ProcessRunnerTests {
  static let shell = URL(fileURLWithPath: "/bin/sh")

  @Test func aCommandsOutputAndExitCodeComeBack() async throws {
    let result = try await ProcessRunner().run(Self.shell, ["-c", "echo out; echo err >&2; exit 3"], timeout: .seconds(5))
    #expect(result == CommandResult(exitCode: 3, stdout: "out\n", stderr: "err\n"))
  }

  @Test func anArgumentIsNeverReadAsShellSyntax() async throws {
    let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/echo"), ["$(whoami); rm -rf ~"], timeout: .seconds(5))
    #expect(result.stdout == "$(whoami); rm -rf ~\n")
  }

  @Test func aCommandThatOverrunsIsStopped() async throws {
    let start = ContinuousClock.now
    await #expect(throws: CommandError.timedOut("sh -c sleep 30")) {
      try await ProcessRunner().run(Self.shell, ["-c", "sleep 30"], timeout: .milliseconds(200))
    }
    #expect(ContinuousClock.now - start < .seconds(5))
  }

  /// A command that shrugs off the polite request to stop is killed after a
  /// moment's grace, so the caller isn't left waiting on it for good.
  @Test func aCommandThatIgnoresBeingAskedToStopIsKilled() async throws {
    let start = ContinuousClock.now
    await #expect(throws: CommandError.timedOut("sh -c trap '' TERM; while :; do :; done")) {
      try await ProcessRunner().run(Self.shell, ["-c", "trap '' TERM; while :; do :; done"], timeout: .milliseconds(200))
    }
    let took = ContinuousClock.now - start
    #expect(took >= ProcessRunner.killGrace && took < .seconds(10))
  }
}
