import Foundation
import Testing

@testable import HollerCore

/// Serves canned HTTP responses to a URLSession, recording each request.
final class StubProtocol: URLProtocol, @unchecked Sendable {
  struct Reply: Sendable {
    var status: Int
    var body: String
  }

  nonisolated(unsafe) static var replies: [Reply] = []
  nonisolated(unsafe) static var requests: [URLRequest] = []
  static let lock = NSLock()

  static func session(_ replies: [Reply]) -> URLSession {
    lock.withLock {
      self.replies = replies
      requests = []
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let reply = Self.lock.withLock {
      Self.requests.append(request)
      return Self.replies.isEmpty ? Reply(status: 500, body: "no reply scripted") : Self.replies.removeFirst()
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Serialized: the stub's replies are shared state.
@Suite(.serialized) struct LLMGatewayHTTPTests {
  static let ok = StubProtocol.Reply(
    status: 200,
    body: #"{"request_id":"r1","choices":[{"message":{"role":"assistant","content":"hello"}}],"usage":{}}"#)

  let request = ChatRequest(model: "claude-sonnet-5-5", messages: [.user("hi")], maxTokens: 10)

  @Test func sendsTheRawKeyAndDecodesTheReply() async throws {
    let gateway = LLMGateway(apiKey: "test-key", session: StubProtocol.session([Self.ok]))
    let completion = try await gateway.complete(request)
    #expect(completion.message.content == "hello")
    let sent = try #require(StubProtocol.requests.first)
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "test-key")
    #expect(sent.httpMethod == "POST")
  }

  @Test func retriesOnceAfterAServerError() async throws {
    let gateway = LLMGateway(
      apiKey: "k", session: StubProtocol.session([.init(status: 503, body: "busy"), Self.ok]))
    #expect(try await gateway.complete(request).message.content == "hello")
    #expect(StubProtocol.requests.count == 2)
  }

  @Test func givesUpAfterTheRetryWithAReadableMessage() async throws {
    let gateway = LLMGateway(
      apiKey: "k", session: StubProtocol.session([.init(status: 429, body: ""), .init(status: 429, body: "")]))
    await #expect {
      try await gateway.complete(request)
    } throws: { error in
      "\(error)" == "LLM Gateway is rate limiting requests. Try again in a moment."
    }
    #expect(StubProtocol.requests.count == 2)
  }

  @Test func badRequestsAreNotRetriedAndExplainThemselves() async throws {
    let body = #"{"metadata":{"errors":["Your account does not have access to this LLM Gateway model"]},"message":"invalid request body","code":400}"#
    let gateway = LLMGateway(apiKey: "k", session: StubProtocol.session([.init(status: 400, body: body)]))
    await #expect {
      try await gateway.complete(request)
    } throws: { error in
      "\(error)"
        == "LLM Gateway returned 400: invalid request body: Your account does not have access to this LLM Gateway model"
    }
    #expect(StubProtocol.requests.count == 1)
  }

  /// Also what an account with no card on file is likely to get, with a key
  /// the key window has just accepted.
  @Test func aRefusedKeySaysWhereToLookAndWhatTheGatewaySaid() async throws {
    let body = #"{"error":"Authentication error, API token missing/invalid","status":"error","request_id":"6e6f340d"}"#
    let gateway = LLMGateway(apiKey: "k", session: StubProtocol.session([.init(status: 401, body: body)]))
    await #expect {
      try await gateway.complete(request)
    } throws: { error in
      "\(error)"
        == "LLM Gateway didn't accept your AssemblyAI key. LLM Gateway needs a card on the account; check that, or "
        + "change the key from the menu's AssemblyAI API Key… (or ASSEMBLYAI_API_KEY, if you set one). "
        + "It said: Authentication error, API token missing/invalid"
    }
    #expect(StubProtocol.requests.count == 1)
    let bare = GatewayError.http(status: 403, body: "").description
    #expect(bare.hasSuffix("(or ASSEMBLYAI_API_KEY, if you set one)."))
    #expect(!bare.contains(".env"))
  }

  @Test func theGatewaysReasonIsReadFromEachShapeOfErrorBody() {
    #expect(GatewayError.reason(in: #"{"error":"No such model","status":"error"}"#) == "No such model")
    #expect(GatewayError.reason(in: #"{"error":{"message":"Payment required","type":"billing"}}"#) == "Payment required")
    #expect(GatewayError.reason(in: #"{"message":"invalid request body","code":400}"#) == "invalid request body")
    #expect(GatewayError.reason(in: " Bad Gateway\n") == "Bad Gateway")
    #expect(GatewayError.reason(in: #"{"error":"key 3f2a9c8e1b7d4e6f0a1b2c3d4e5f6a7b is not valid"}"#) == "key [redacted key] is not valid")
  }

  @Test func warmUpHitsTheModelListWithoutTheKey() async throws {
    let gateway = LLMGateway(apiKey: "k", session: StubProtocol.session([.init(status: 200, body: "{}")]))
    await gateway.warmUp()
    let sent = try #require(StubProtocol.requests.first)
    #expect(sent.url?.absoluteString == "https://llm-gateway.assemblyai.com/v1/models")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
  }
}
