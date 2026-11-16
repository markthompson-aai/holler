import AVFoundation
import OSLog
import HollerCore
import HollerSpeech

/// Reads answers aloud: AssemblyAI's voice ("aai-anna"), falling back to
/// the Mac's if a request fails, so an answer is always spoken.
enum Speaker {
  private static let logger = Logger(subsystem: "com.assemblyai.holler", category: "Speaker")

  /// `apiKey` is read on every answer read aloud, so a reload's new key is
  /// used from the next one on.
  @MainActor static func make(apiKey: @escaping @Sendable () -> String, macVoice: MacVoice) -> FallbackVoice {
    FallbackVoice(
      primary: { try await SpeechOutput(apiKey: apiKey()).speak($0) }, fallback: macVoice,
      onFailure: { logger.error("AssemblyAI voice failed, using the Mac's: \(String(describing: $0), privacy: .public)") })
  }
}

/// The Mac's own voices: the fallback.
@MainActor
final class MacVoice: VoiceOutput {
  private let synthesizer = AVSpeechSynthesizer()
  private var voice: AVSpeechSynthesisVoice?

  /// `preferred` is a voice name or identifier, e.g. "Zoe" or
  /// "com.apple.voice.premium.en-US.Zoe". Otherwise the best-quality voice
  /// installed for the user's language.
  init(preferred: String?) {
    voice = Self.pick(preferred)
  }

  /// Takes the voice a reload names, from the next answer on.
  func prefer(_ preferred: String?) {
    voice = Self.pick(preferred)
  }

  private static func pick(_ preferred: String?) -> AVSpeechSynthesisVoice? {
    let voices = AVSpeechSynthesisVoice.speechVoices().filter {
      !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
    }
    if let preferred, let match = voices.first(where: { $0.identifier == preferred || $0.name == preferred }) {
      return match
    }
    let language = AVSpeechSynthesisVoice.currentLanguageCode()
    return voices.filter { $0.language == language }.max { $0.quality.rawValue < $1.quality.rawValue }
      ?? AVSpeechSynthesisVoice(language: language)
  }

  func speak(_ text: String) {
    stop()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    synthesizer.speak(utterance)
  }

  func stop() {
    if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
  }
}
