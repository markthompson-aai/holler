import AppKit
import Darwin

/// The terminal app Herdr runs in (Ghostty, iTerm, Terminal…), found by walking
/// up from a `herdr` process to the first parent that is a regular app, so
/// none is named here.
@MainActor
enum HerdrTerminal {
  /// After a jump, puts the agent Herdr just focused in front of you, with the
  /// keyboard. Does nothing if Herdr isn't running in a terminal app.
  static func bringToFront() {
    find()?.activate()
  }

  static func find() -> NSRunningApplication? {
    let processes = Self.processes()
    let ownPid = getpid()
    for pid in processes.keys.sorted() where processes[pid]?.name == "herdr" {
      var current = pid
      // Stops at launchd, and at Holler itself, whose own `herdr` calls lead
      // back to whatever launched it (Terminal, under `swift run`).
      while current > 1, current != ownPid, let process = processes[current] {
        if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
          return app
        }
        current = process.parent
      }
    }
    return nil
  }

  /// Every process's parent and short name, from the kernel's process table.
  private static func processes() -> [pid_t: (parent: pid_t, name: String)] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [:] }
    // Room for processes started between the two calls.
    var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
    size = table.count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &table, &size, nil, 0) == 0 else { return [:] }
    var result: [pid_t: (parent: pid_t, name: String)] = [:]
    for var entry in table.prefix(size / MemoryLayout<kinfo_proc>.stride) {
      let name = withUnsafeBytes(of: &entry.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      result[entry.kp_proc.p_pid] = (entry.kp_eproc.e_ppid, name)
    }
    return result
  }
}
