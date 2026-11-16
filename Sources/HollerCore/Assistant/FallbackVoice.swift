import Foundation

/// Speaks with `primary` (AssemblyAI's streaming voice in the app); if that
/// fails, `fallback` (the Mac's voice) reads the same text, so an asked
/// question is never met with silence. A stop during `primary` is not a
/// failure: nothing else is read.
@MainActor
public final class FallbackVoice: VoiceOutput {
  private let primary: @Sendable (String) async throws -> Void
  private let fallback: any VoiceOutput
  private let onFailure: (any Error) -> Void
  private var reading: Task<Void, Never>?

  /// `primary` runs until the last word has played, and stops when its task is cancelled.
  public init(
    primary: @escaping @Sendable (String) async throws -> Void, fallback: any VoiceOutput,
    onFailure: @escaping (any Error) -> Void = { _ in }
  ) {
    self.primary = primary
    self.fallback = fallback
    self.onFailure = onFailure
  }

  public func speak(_ text: String) {
    stop()
    let primary = primary
    reading = Task {
      do {
        try await primary(text)
      } catch {
        // A stop closes the socket, which can surface as any error.
        guard !Task.isCancelled else { return }
        onFailure(error)
        fallback.speak(text)
      }
    }
  }

  public func stop() {
    reading?.cancel()
    reading = nil
    fallback.stop()
  }

  /// Waits for the current read's primary attempt. For tests.
  func settle() async {
    await reading?.value
  }
}
