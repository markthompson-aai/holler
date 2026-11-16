import Foundation
import Testing

@testable import HollerCore

/// Reading Herdr's event stream: the lines it sends, and a real socket.
@Suite struct HerdrEventsTests {
  func parse(_ line: String) throws -> HerdrEvent? {
    try HerdrEvent.parse(Data(line.utf8))
  }

  @Test func theLinesHollerFollowsAreRecognised() throws {
    #expect(try parse(#"{"id":"holler:events","result":{"type":"subscription_started"}}"#) == .subscribed)
    #expect(
      try parse(#"{"event":"pane.agent_status_changed","data":{"pane_id":"wH:pB","workspace_id":"wH","agent_status":"idle"}}"#)
        == .statusChanged(paneId: "wH:pB", status: "idle"))
    #expect(try parse(#"{"event":"pane_agent_status_changed","data":{"pane_id":"w1:p1","agent_status":"blocked"}}"#)
      == .statusChanged(paneId: "w1:p1", status: "blocked"))
    #expect(try parse(#"{"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w1:p1","workspace_id":"w1"}}"#) == .agentsChanged)
    #expect(try parse(#"{"event":"pane.agent_detected","data":{"pane_id":"w1:p1"}}"#) == .agentsChanged)
    #expect(try parse(#"{"event":"tab_created","data":{"tab":{}}}"#) == .agentsChanged)
  }

  @Test func otherLinesAreIgnored() throws {
    #expect(try parse(#"{"event":"pane_focused","data":{"pane_id":"w1:p1"}}"#) == nil)
    #expect(try parse(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1"}}"#) == nil)
    #expect(try parse(#"{"id":"1","result":{"type":"pong"}}"#) == nil)
    #expect(try parse("not json") == nil)
  }

  @Test func anErrorHerdrReportsIsThrown() {
    #expect(throws: HerdrError.commandFailed(command: "events subscribe", detail: "unknown pane")) {
      try parse(#"{"id":"holler:events","error":{"code":"pane_not_found","message":"unknown pane"}}"#)
    }
  }

  @Test func theRequestOnlySubscribes() throws {
    let data = HerdrSocket.subscribeRequest(panes: ["w1:p1", "wH:pB"])
    #expect(data.last == 0x0A)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["method"] as? String == "events.subscribe")
    let subscriptions = try #require((json["params"] as? [String: Any])?["subscriptions"] as? [[String: String]])
    let statuses = subscriptions.filter { $0["type"] == "pane.agent_status_changed" }.compactMap { $0["pane_id"] }
    #expect(statuses == ["w1:p1", "wH:pB"])
    #expect(subscriptions.contains { $0 == ["type": "pane.closed"] })
  }

  @Test func theSocketIsFoundInsideAndOutsideHerdr() {
    #expect(HerdrSocket.locate(environment: ["HERDR_SOCKET_PATH": "/x/herdr.sock"]).path == "/x/herdr.sock")
    #expect(HerdrSocket.locate(environment: ["HOME": "/Users/test"]).path == "/Users/test/.config/herdr/herdr.sock")
  }

  @Test func eventsArriveOverARealSocketUntilItCloses() async throws {
    let server = try LineServer(lines: [
      #"{"id":"holler:events","result":{"type":"subscription_started"}}"#,
      #"{"event":"pane_focused","data":{"pane_id":"w1:p1"}}"#,
      #"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"working"}}"#,
    ])
    var events: [HerdrEvent] = []
    for try await event in HerdrSocket(path: server.path).subscribe(panes: ["w1:p1"]) { events.append(event) }
    #expect(events == [.subscribed, .statusChanged(paneId: "w1:p1", status: "working")])
    #expect(server.received.contains(#""method":"events.subscribe""#))
  }

  @Test func aMissingSocketFailsTheStream() async {
    let stream = HerdrSocket(path: NSTemporaryDirectory() + "no-such-\(UUID().uuidString.prefix(8)).sock").subscribe(panes: [])
    await #expect(throws: HerdrError.self) {
      for try await _ in stream {}
    }
  }
}

/// A Unix socket server for one client: reads its request line, sends
/// `lines`, then hangs up.
final class LineServer: @unchecked Sendable {
  let path = NSTemporaryDirectory() + "h-\(UUID().uuidString.prefix(8)).sock"
  private let lock = NSLock()
  private var _received = ""
  private let done = DispatchSemaphore(value: 0)

  var received: String {
    done.wait()
    done.signal()
    return lock.withLock { _received }
  }

  init(lines: [String]) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(fd, 1) == 0 else { throw CommandError.launchFailed("test socket") }
    let path = path
    Thread.detachNewThread { [self] in
      let client = accept(fd, nil, nil)
      var request = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while !request.contains(0x0A) {
        let count = read(client, &buffer, buffer.count)
        if count <= 0 { break }
        request.append(contentsOf: buffer[..<count])
      }
      lock.withLock { _received = String(decoding: request, as: UTF8.self) }
      let reply = Data(lines.map { $0 + "\n" }.joined().utf8)
      _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
      close(client)
      close(fd)
      unlink(path)
      done.signal()
    }
  }
}
