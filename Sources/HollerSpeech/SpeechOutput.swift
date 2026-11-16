import AVFoundation
import Synchronization
import HollerCore

/// Reads text aloud with AssemblyAI's voice, playing each chunk as it arrives.
///
/// `speak` runs until the last sample has played. To stop early, cancel the
/// task awaiting it: playback goes silent at once and the request is cancelled.
public struct SpeechOutput: Sendable {
  private let speech: AssemblyAISpeech

  public init(apiKey: String, voice: String = AssemblyAISpeech.defaultVoice) {
    speech = AssemblyAISpeech(apiKey: apiKey, voice: voice)
  }

  public func speak(_ text: String) async throws {
    let player = StreamingPCMPlayer(sampleRate: AssemblyAISpeech.sampleRate)
    try await withTaskCancellationHandler {
      do {
        for try await chunk in speech.audio(for: text) { player.enqueue(chunk) }
      } catch {
        player.stop()
        throw error
      }
      await player.drain()
    } onCancel: {
      player.stop()
    }
  }
}

// The player and its schedule come from Blurt's read-aloud engine
// (Sources/BlurtEngine/TTS, MIT, © 2026 Alex Kroman), where they're internal.

/// Plays PCM16 LE mono chunks as they arrive, using an
/// `AVSampleBufferAudioRenderer` driven by a render synchronizer: it takes
/// timestamped buffers as they come, so the first word doesn't wait for the
/// last one to be synthesized. Thread-safe; all mutable state sits behind one
/// `Mutex`, and the AV objects are only touched inside it.
final class StreamingPCMPlayer: @unchecked Sendable {
  private struct State {
    var schedule: PCMSchedule
    var stopped = false
  }

  private let renderer = AVSampleBufferAudioRenderer()
  private let synchronizer = AVSampleBufferRenderSynchronizer()
  private let format: CMAudioFormatDescription?
  private let sampleRate: Int32
  private let state: Mutex<State>

  init(sampleRate: Int) {
    self.sampleRate = Int32(sampleRate)
    self.state = Mutex(State(schedule: PCMSchedule(sampleRate: sampleRate)))
    var description = AudioStreamBasicDescription(
      mSampleRate: Float64(sampleRate),
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
      mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    self.format = format
    synchronizer.addRenderer(renderer)
  }

  func enqueue(_ pcm: Data) {
    let frames = pcm.count / 2
    guard frames > 0, let format else { return }
    state.withLock { state in
      guard !state.stopped else { return }
      let first = !state.schedule.started
      let at = state.schedule.place(frames: frames, now: CMTimeGetSeconds(synchronizer.currentTime()))
      let time = CMTime(seconds: at, preferredTimescale: sampleRate)
      guard let buffer = Self.sampleBuffer(pcm, frames: frames, format: format, at: time) else { return }
      renderer.enqueue(buffer)
      if first { synchronizer.setRate(1, time: .zero) }
    }
  }

  /// Returns once everything enqueued has played, or once `stop()` is called.
  /// Also bounded by the wall clock, since the synchronizer's clock only moves
  /// while an output device is consuming audio.
  func drain() async {
    let queued = remaining() ?? 0
    let deadline = ContinuousClock.now + .seconds(queued) + .seconds(2)
    while ContinuousClock.now < deadline {
      guard let remaining = remaining(), remaining > 0 else { break }
      try? await Task.sleep(for: .milliseconds(min(100, Int(remaining * 1000) + 10)))
      if Task.isCancelled { break }
    }
    stop()
  }

  /// Seconds of audio still ahead of the clock, or nil once stopped.
  private func remaining() -> Double? {
    state.withLock { state in
      state.stopped ? nil : state.schedule.remaining(now: CMTimeGetSeconds(synchronizer.currentTime()))
    }
  }

  /// Silences playback at once and discards anything queued. Idempotent.
  func stop() {
    state.withLock { state in
      guard !state.stopped else { return }
      state.stopped = true
      synchronizer.setRate(0, time: synchronizer.currentTime())
      renderer.flush()
    }
  }

  private static func sampleBuffer(
    _ pcm: Data, frames: Int, format: CMAudioFormatDescription, at time: CMTime
  ) -> CMSampleBuffer? {
    let length = frames * 2
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
      let block
    else { return nil }
    let copied = pcm.withUnsafeBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else { return -1 }
      return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    }
    guard copied == noErr else { return nil }
    var buffer: CMSampleBuffer?
    guard
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil,
        sampleBufferOut: &buffer) == noErr
    else { return nil }
    return buffer
  }
}

/// Where each chunk lands on the playback timeline: right after the previous
/// one, or, if the network fell behind the clock, `lead` into the future so the
/// renderer doesn't drop it as late. A late chunk costs a small gap, not lost
/// words. The first chunk gets the lead too, so it's in hand before the clock starts.
struct PCMSchedule {
  static let lead = 0.05

  let sampleRate: Double
  private(set) var nextTime = 0.0
  private(set) var started = false

  init(sampleRate: Int) {
    self.sampleRate = Double(sampleRate)
  }

  mutating func place(frames: Int, now: Double) -> Double {
    if !started || nextTime < now {
      nextTime = (started ? now : 0) + Self.lead
    }
    started = true
    let at = nextTime
    nextTime += Double(frames) / sampleRate
    return at
  }

  func remaining(now: Double) -> Double {
    started ? max(0, nextTime - now) : 0
  }
}
