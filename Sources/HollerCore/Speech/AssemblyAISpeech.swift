import Foundation

public enum SpeechError: Error, Equatable, CustomStringConvertible {
  case http(status: Int, body: String)

  public var description: String {
    switch self {
    case .http(let status, _) where status == 401 || status == 403:
      "AssemblyAI text-to-speech rejected the API key."
    case .http(let status, let body):
      "AssemblyAI text-to-speech returned \(status): \(Self.reason(in: body))"
    }
  }

  /// The service's own explanation, e.g. "encoding: must be one of pcm_s16le, …".
  static func reason(in body: String) -> String {
    let json = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
    return json?["message"]?.stringValue ?? String(body.prefix(300))
  }
}

/// AssemblyAI's text-to-speech, streamed as raw PCM16 little-endian mono so
/// playback can start on the first chunk rather than after the whole clip.
///
/// The HTTP API's Create speech route
/// (https://www.assemblyai.com/docs/tts/api-reference/http-api/create-speech).
/// With `pcm_s16le` and `stream: true` the first audio arrives in about
/// 0.4 s, and speech is generated about three times faster than it plays.
public struct AssemblyAISpeech: Sendable {
  public static let endpoint = URL(string: "https://tts.us.assemblyai.com/v1/speech")!
  public static let defaultVoice = "aai-anna"
  public static let sampleRate = 24_000
  /// About 0.1 s of audio per chunk handed to the player.
  static let chunkBytes = 4_800

  let apiKey: String
  let voice: String
  let session: URLSession

  public init(apiKey: String, voice: String = defaultVoice, session: URLSession = .shared) {
    self.apiKey = apiKey
    self.voice = voice
    self.session = session
  }

  /// PCM chunks in playback order, each a whole number of samples.
  /// Cancelling the consumer cancels the request.
  public func audio(for text: String) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await stream(text) { continuation.yield($0) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func request(for text: String) throws -> URLRequest {
    var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: JSONValue = [
      "text": .string(text), "voice_id": .string(voice), "language": "english",
      "sample_rate": .number(Double(Self.sampleRate)), "encoding": "pcm_s16le", "stream": true,
    ]
    request.httpBody = try JSONEncoder().encode(body)
    return request
  }

  private func stream(_ text: String, onAudio: (Data) -> Void) async throws {
    let (bytes, response) = try await session.bytes(for: request(for: text))
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      var body = Data()
      for try await byte in bytes where body.count < 2_000 { body.append(byte) }
      throw SpeechError.http(status: status, body: String(decoding: body, as: UTF8.self))
    }
    var pending = Data()
    pending.reserveCapacity(Self.chunkBytes)
    for try await byte in bytes {
      pending.append(byte)
      if pending.count == Self.chunkBytes {
        onAudio(pending)
        pending.removeAll(keepingCapacity: true)
      }
    }
    // A stray odd byte would shift every later sample.
    pending.count -= pending.count % 2
    if !pending.isEmpty { onAudio(pending) }
  }
}
