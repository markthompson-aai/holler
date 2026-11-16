@preconcurrency import AVFoundation
import BlurtEngine
import Foundation
import HollerCore

/// Speech to text through Blurt's engine: its mic capture and its streaming
/// Dictation API client, which uploads audio while the user is still talking.
public struct SpeechInput: Sendable {
  public static let sampleRate = 16_000

  let transcriber: AssemblyAITranscriber

  /// Points Blurt's engine at Holler's own logs, defaults and Keychain
  /// service. Call once, before constructing anything else from the engine.
  public static func configureEngine() {
    HostIdentity.configure(
      HostIdentity(
        productName: "Holler",
        subsystem: "com.assemblyai.holler",
        keychainService: "holler",
        defaultsPrefix: "Holler",
        logDirectoryName: "Holler"))
  }

  public init(apiKey: String) {
    self.init(apiKey: { apiKey })
  }

  /// Reads the key on every request, so a reload's new key is used from the
  /// next one on.
  public init(apiKey: @escaping @Sendable () -> String?) {
    transcriber = AssemblyAITranscriber(
      apiKeyProvider: apiKey,
      // The Dictation API's cleanup resolves self-corrections ("ask the,
      // no, tell the search agent…"), which is what the model should see.
      enhancedTranscripts: { true },
      customStyle: { nil })
  }

  public func warmUp() async {
    await transcriber.warmUp()
  }

  public func transcribe(_ frames: AsyncStream<Data>, keyTerms: [String]) async throws -> String {
    let context = TranscriptionContext(appName: nil, priorText: SpeechHints.sttPrompt, keyTerms: keyTerms)
    return try await transcriber.transcribe(frames: frames, sampleRate: Self.sampleRate, context: context)
  }

  /// Decodes an audio file to 16 kHz mono 16-bit PCM and streams it in
  /// 100 ms frames, as the microphone would.
  public static func frames(fromFile url: URL) throws -> AsyncStream<Data> {
    let file = try AVAudioFile(forReading: url)
    guard
      let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: file.processingFormat, to: target),
      let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw CocoaError(.fileReadCorruptFile) }
    try file.read(into: input)

    let ratio = target.sampleRate / file.processingFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    nonisolated(unsafe) var delivered = false
    var conversionError: NSError?
    converter.convert(to: output, error: &conversionError) { _, status in
      if delivered {
        status.pointee = .endOfStream
        return nil
      }
      delivered = true
      status.pointee = .haveData
      return input
    }
    if let conversionError { throw conversionError }

    let bytes = Data(
      bytes: output.int16ChannelData![0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    let frameBytes = sampleRate / 10 * MemoryLayout<Int16>.size
    return AsyncStream { continuation in
      var offset = 0
      while offset < bytes.count {
        continuation.yield(bytes.subdata(in: offset..<min(offset + frameBytes, bytes.count)))
        offset += frameBytes
      }
      continuation.finish()
    }
  }
}

/// The microphone, via Blurt's capture stack (device selection, liveness gate).
public struct Microphone: Sendable {
  let capture = MicCapture()

  public init() {}

  public func start() async throws -> AsyncStream<Data> {
    try await capture.start()
  }

  /// Ends the recording; the frame stream finishes. Returns how much audio was
  /// captured.
  @discardableResult
  public func stop() async throws -> Duration {
    // 16-bit mono PCM at the capture rate.
    let bytes = try await capture.stop()
    return .milliseconds(bytes * 1_000 / (SyncSTTLimits.sampleRate * MemoryLayout<Int16>.size))
  }
}

/// The microphone permission, when it stops Holler listening.
public enum MicrophonePermission {
  /// Why Holler can't use the microphone and where to change that, for the
  /// note and the menu; nil when it may, or hasn't asked yet.
  public static var problem: String? {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .denied:
      "Holler isn't allowed to use the microphone. Switch it on in System Settings › Privacy & Security › Microphone."
    case .restricted:
      "This Mac doesn't let Holler use the microphone. It's restricted in System Settings › Privacy & Security › Microphone, perhaps by a profile."
    default: nil
    }
  }
}

/// A press that couldn't listen because the microphone isn't allowed, in
/// the note's words. Without the check, the capture fails some other way
/// that doesn't mention the permission.
struct MicrophoneNotAllowed: LocalizedError {
  let errorDescription: String?
}

/// `VoiceInput` for the app: Blurt's mic capture feeding a Dictation API
/// request that opens on press, so audio uploads while the user is talking.
public actor BlurtVoiceInput: VoiceInput {
  private let speech: SpeechInput
  private let capture = MicCapture()
  private var transcription: Task<String, any Error>?

  /// Mic level, about 20 Hz, for the listening meter. Single consumer.
  public nonisolated var levels: AsyncStream<Float> { capture.levels }

  public init(speech: SpeechInput) {
    self.speech = speech
  }

  /// Pays the one-off audio-stack and TLS set-up cost before the first press.
  public func warmUp() async {
    await capture.warmUp()
    await speech.warmUp()
  }

  public func start(keyTerms: [String]) async throws {
    if let problem = MicrophonePermission.problem { throw MicrophoneNotAllowed(errorDescription: problem) }
    let frames = try await capture.start()
    let speech = speech
    transcription = Task { try await speech.transcribe(frames, keyTerms: keyTerms) }
  }

  public func finish() async throws -> String {
    guard let transcription else { return "" }
    self.transcription = nil
    let bytes = try await capture.stop()
    // Under 100 ms of audio (a hesitant press, or a release before a Bluetooth
    // mic connected) the transcriber refuses with audioTooShort. Like Blurt,
    // treat it as nothing said rather than an error.
    guard bytes >= SyncSTTLimits.minPCMBytes else {
      transcription.cancel()
      return ""
    }
    return try await transcription.value
  }

  public func cancel() async {
    transcription?.cancel()
    transcription = nil
    try? await capture.cancelCapture()
  }
}
