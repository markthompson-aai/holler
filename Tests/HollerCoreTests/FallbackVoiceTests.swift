import Foundation
import Testing

@testable import HollerCore

@MainActor
@Suite struct FallbackVoiceTests {
  struct SocketClosed: Error {}

  @Test func aFailedPrimaryVoiceFallsBackToTheSameText() async {
    let mac = FakeSpeaker()
    var failures = 0
    let voice = FallbackVoice(primary: { _ in throw SocketClosed() }, fallback: mac, onFailure: { _ in failures += 1 })
    voice.speak("Two agents need you.")
    await voice.settle()
    #expect(mac.events == ["stop", "speak: Two agents need you."])
    #expect(failures == 1)
  }

  @Test func aWorkingPrimaryVoiceLeavesTheFallbackSilent() async {
    let mac = FakeSpeaker()
    let spoken = Spoken()
    let voice = FallbackVoice(primary: { await spoken.add($0) }, fallback: mac)
    voice.speak("Two agents need you.")
    await voice.settle()
    #expect(await spoken.texts == ["Two agents need you."])
    #expect(!mac.events.contains { $0.hasPrefix("speak") })
  }

  @Test func stoppingIsNotAFailure() async {
    let mac = FakeSpeaker()
    let voice = FallbackVoice(
      primary: { _ in
        try await Task.sleep(for: .seconds(10))
      }, fallback: mac)
    voice.speak("A long answer.")
    voice.stop()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!mac.events.contains { $0.hasPrefix("speak") })
  }
}

actor Spoken {
  var texts: [String] = []
  func add(_ text: String) { texts.append(text) }
}
