import Foundation

/// What Holler follows on Herdr's event stream.
public enum HerdrEvent: Sendable, Equatable {
  /// Herdr has started sending the events subscribed to.
  case subscribed
  case statusChanged(paneId: String, status: String)
  /// A pane or tab opened, closed or moved, or an agent started or left a
  /// pane: the agents may not be the ones subscribed to any more.
  case agentsChanged

  /// One line of the stream: Herdr writes one JSON object per line. Nil for
  /// a line Holler doesn't follow; an error Herdr reports is thrown.
  static func parse(_ line: Data) throws -> HerdrEvent? {
    guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
    if let error = json["error"] as? [String: Any] {
      let detail = (error["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? error["code"] as? String ?? "error"
      throw HerdrError.commandFailed(command: "events subscribe", detail: detail)
    }
    if let result = json["result"] as? [String: Any] {
      return result["type"] as? String == "subscription_started" ? .subscribed : nil
    }
    // Subscribed events are named "pane.agent_status_changed", others "pane_closed".
    guard let name = (json["event"] as? String)?.replacingOccurrences(of: ".", with: "_") else { return nil }
    let data = json["data"] as? [String: Any] ?? [:]
    switch name {
    case "pane_agent_status_changed":
      guard let pane = data["pane_id"] as? String, let status = data["agent_status"] as? String else { return nil }
      return .statusChanged(paneId: pane, status: status)
    case "pane_created", "pane_closed", "pane_moved", "pane_exited", "pane_agent_detected", "tab_created", "tab_closed",
      "workspace_closed":
      return .agentsChanged
    default:
      return nil
    }
  }
}

/// A live feed of Herdr's events. Each call opens its own subscription,
/// which ends when the stream is dropped.
public protocol HerdrEventSource: Sendable {
  /// Status changes for `panes`, and panes and tabs opening and closing
  /// anywhere. The stream finishes or throws if the connection drops.
  func subscribe(panes: [String]) -> AsyncThrowingStream<HerdrEvent, any Error>
}

/// Herdr's socket API: newline-delimited JSON over a Unix socket. Only ever
/// sends `events.subscribe`, so it can't change anything in Herdr. Herdr
/// takes one subscription per connection, so a new set of panes means a new
/// connection.
public struct HerdrSocket: HerdrEventSource {
  public let path: String

  public init(path: String) {
    self.path = path
  }

  /// Where Herdr's default session listens: `HERDR_SOCKET_PATH` inside Herdr,
  /// otherwise its config folder, since a GUI app doesn't inherit that.
  public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> HerdrSocket {
    let home = environment["HOME"] ?? NSHomeDirectory()
    return HerdrSocket(path: environment["HERDR_SOCKET_PATH"] ?? "\(home)/.config/herdr/herdr.sock")
  }

  static func subscribeRequest(panes: [String]) -> Data {
    let global = [
      "pane.created", "pane.closed", "pane.moved", "pane.exited", "pane.agent_detected", "tab.created", "tab.closed",
      "workspace.closed",
    ].map { ["type": $0] }
    let statuses = panes.map { ["type": "pane.agent_status_changed", "pane_id": $0] }
    let request: [String: Any] = [
      "id": "holler:events", "method": "events.subscribe", "params": ["subscriptions": global + statuses],
    ]
    // Plain strings in plain containers always serialize.
    return (try! JSONSerialization.data(withJSONObject: request)) + Data("\n".utf8)
  }

  public func subscribe(panes: [String]) -> AsyncThrowingStream<HerdrEvent, any Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: HerdrEvent.self, throwing: (any Error).self)
    let connection = SocketConnection()
    continuation.onTermination = { _ in connection.shutDown() }
    let (path, request) = (path, Self.subscribeRequest(panes: panes))
    // Reads block, so the connection gets a thread of its own.
    Thread.detachNewThread {
      do {
        try connection.open(path)
        try connection.write(request)
        var buffer = Data()
        while let chunk = try connection.read() {
          buffer.append(chunk)
          while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            if let event = try HerdrEvent.parse(Data(line)) { continuation.yield(event) }
          }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
      connection.close()
    }
    return stream
  }
}

/// One Unix socket connection. `shutDown()` may come from any thread, and
/// wakes a blocked `read()`; only the reading thread closes the descriptor,
/// so it's never reused while still in use.
private final class SocketConnection: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32 = -1
  private var isShutDown = false

  func open(_ path: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Self.failure("socket") }
    // A write after Herdr hangs up fails with EPIPE instead of killing Holler.
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      Darwin.close(fd)
      throw HerdrError.commandFailed(command: "events subscribe", detail: "socket path too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      let error = Self.failure("connect to \(path)")
      Darwin.close(fd)
      throw error
    }
    let cancelled = lock.withLock {
      descriptor = fd
      return isShutDown
    }
    if cancelled { Darwin.shutdown(fd, SHUT_RDWR) }
  }

  func write(_ data: Data) throws {
    let fd = lock.withLock { descriptor }
    try data.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let count = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
        guard count > 0 else { throw Self.failure("write") }
        sent += count
      }
    }
  }

  /// The next bytes Herdr sent; nil once the connection has closed.
  func read() throws -> Data? {
    let fd = lock.withLock { descriptor }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count > 0 { return Data(buffer[..<count]) }
      if count == 0 || lock.withLock({ isShutDown }) { return nil }
      if errno == EINTR { continue }
      throw Self.failure("read")
    }
  }

  func shutDown() {
    lock.withLock {
      isShutDown = true
      if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR) }
    }
  }

  func close() {
    lock.withLock {
      if descriptor >= 0 { Darwin.close(descriptor) }
      descriptor = -1
    }
  }

  private static func failure(_ step: String) -> HerdrError {
    .commandFailed(command: "events subscribe", detail: "\(step): \(String(cString: strerror(errno)))")
  }
}
