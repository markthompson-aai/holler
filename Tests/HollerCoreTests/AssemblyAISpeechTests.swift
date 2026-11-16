import Foundation
import Testing

@testable import HollerCore

/// In the gateway's suite because the HTTP stub's replies are shared state,
/// and that suite is serialized.
extension LLMGatewayHTTPTests {
  func speech(_ replies: [StubProtocol.Reply]) -> AssemblyAISpeech {
    AssemblyAISpeech(apiKey: "test-key", session: StubProtocol.session(replies))
  }

  func collect(_ stream: AsyncThrowingStream<Data, any Error>) async throws -> [Data] {
    var chunks: [Data] = []
    for try await chunk in stream { chunks.append(chunk) }
    return chunks
  }

  @Test func speechAsksForStreamedPCMInAnna() async throws {
    _ = try await collect(speech([.init(status: 200, body: "")]).audio(for: "Two agents need you."))
    let sent = try #require(StubProtocol.requests.first)
    #expect(sent.url == AssemblyAISpeech.endpoint && sent.httpMethod == "POST")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "test-key")
    let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.httpBodyStream.map(Self.read)))
    #expect(body["text"]?.stringValue == "Two agents need you.")
    #expect(body["voice_id"]?.stringValue == "aai-anna")
    #expect(body["encoding"]?.stringValue == "pcm_s16le" && body["sample_rate"]?.intValue == 24_000)
    #expect(body["stream"] == .bool(true))
  }

  @Test func speechComesInWholeSampleChunks() async throws {
    // 1.5 chunks of audio plus a stray odd byte.
    let pcm = String(repeating: "a", count: AssemblyAISpeech.chunkBytes * 3 / 2 + 1)
    let chunks = try await collect(speech([.init(status: 200, body: pcm)]).audio(for: "hi"))
    #expect(chunks.map(\.count) == [AssemblyAISpeech.chunkBytes, AssemblyAISpeech.chunkBytes / 2])
  }

  @Test func speechErrorsExplainThemselves() async throws {
    let body = #"{"code":"invalid_parameter","message":"encoding: must be one of pcm_s16le or mp3"}"#
    do {
      _ = try await collect(speech([.init(status: 422, body: body)]).audio(for: "hi"))
      Issue.record("expected an error")
    } catch let error as SpeechError {
      #expect(error.description == "AssemblyAI text-to-speech returned 422: encoding: must be one of pcm_s16le or mp3")
    }
  }

  static func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
