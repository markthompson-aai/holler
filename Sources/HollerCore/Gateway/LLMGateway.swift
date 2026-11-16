import Foundation

public protocol ChatCompleting: Sendable {
  func complete(_ request: ChatRequest) async throws -> ChatCompletion
}

public enum GatewayError: Error, Equatable, CustomStringConvertible {
  case http(status: Int, body: String)
  case undecodable(String)

  /// Worded for the note: what went wrong and what to do, not a raw body.
  public var description: String {
    switch self {
    case .http(let status, let body) where status == 401 || status == 403:
      // What an account with no card on file gets too, with a key that's
      // fine everywhere else, so say both, and what the gateway said.
      "LLM Gateway didn't accept your AssemblyAI key. LLM Gateway needs a card on the account; check that, or "
        + "change the key from the menu's AssemblyAI API Key… (or ASSEMBLYAI_API_KEY, if you set one)."
        + (Self.reason(in: body).isEmpty ? "" : " It said: \(Self.reason(in: body))")
    case .http(429, _):
      "LLM Gateway is rate limiting requests. Try again in a moment."
    case .http(let status, _) where status >= 500:
      "LLM Gateway had a server problem (\(status)). Try again."
    case .http(let status, let body):
      "LLM Gateway returned \(status): \(Self.reason(in: body))"
    case .undecodable(let detail):
      "Couldn't read LLM Gateway's response: \(detail.prefix(200))"
    }
  }

  /// Rate limits and server errors are worth one retry; a bad request isn't.
  var isTransient: Bool {
    if case .http(let status, _) = self { status == 429 || status >= 500 } else { false }
  }

  /// The gateway's own explanation from an error body, e.g. "invalid request
  /// body: Your account does not have access to this LLM Gateway model", or
  /// "Authentication error, API token missing/invalid" from a body that
  /// holds it as `error`. The body's own words when it isn't JSON.
  static func reason(in body: String) -> String {
    // Redacted, in case an error ever quotes the key it was sent: this goes
    // in the note and the log.
    guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)) else {
      return Redaction.redact(String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
    }
    var parts: [String] = []
    if let error = json["error"]?.stringValue { parts.append(error) }
    if let message = (json["message"] ?? json["error"]?["message"])?.stringValue { parts.append(message) }
    if case .array(let errors)? = json["metadata"]?["errors"] { parts += errors.compactMap(\.stringValue) }
    return Redaction.redact(parts.isEmpty ? String(body.prefix(300)) : parts.joined(separator: ": "))
  }
}

/// AssemblyAI LLM Gateway chat completions.
/// https://www.assemblyai.com/docs/llm-gateway/quickstart
public struct LLMGateway: ChatCompleting {
  public static let defaultEndpoint = URL(string: "https://llm-gateway.assemblyai.com/v1/chat/completions")!
  static let retryDelay: Duration = .milliseconds(800)

  let apiKey: String
  let endpoint: URL
  let session: URLSession

  /// Reuse one gateway (and so one URLSession) for the app's lifetime: the
  /// pooled keep-alive connection skips the TLS handshake on later turns.
  public init(apiKey: String, endpoint: URL = defaultEndpoint, session: URLSession = .shared) {
    self.apiKey = apiKey
    self.endpoint = endpoint
    self.session = session
  }

  /// Retries once after a short pause on a rate limit, server error or dropped
  /// connection, so a blip mid-request costs a second rather than the answer.
  public func complete(_ request: ChatRequest) async throws -> ChatCompletion {
    do {
      return try await send(request)
    } catch where Self.isTransient(error) {
      try await Task.sleep(for: Self.retryDelay)
      return try await send(request)
    }
  }

  /// Opens (or keeps open) the pooled connection to the gateway, so the next
  /// completion doesn't pay for DNS, TCP and TLS. The model list needs no key.
  public func warmUp() async {
    var request = URLRequest(url: endpoint.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("models"), timeoutInterval: 5)
    request.httpMethod = "GET"
    _ = try? await session.data(for: request)
  }

  private func send(_ request: ChatRequest) async throws -> ChatCompletion {
    var urlRequest = URLRequest(url: endpoint, timeoutInterval: 60)
    urlRequest.httpMethod = "POST"
    // The raw key, no "Bearer" prefix.
    urlRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try Self.encoder.encode(request)

    let (data, response) = try await session.data(for: urlRequest)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw GatewayError.http(status: status, body: String(decoding: data, as: UTF8.self))
    }
    do {
      return try JSONDecoder().decode(ChatResponse.self, from: data).completion
    } catch {
      throw GatewayError.undecodable("\(error)")
    }
  }

  static func isTransient(_ error: any Error) -> Bool {
    if let error = error as? GatewayError { return error.isTransient }
    if let error = error as? URLError {
      return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
    }
    return false
  }

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()
}
