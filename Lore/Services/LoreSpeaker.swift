import AVFoundation
import Foundation

@MainActor
final class LoreSpeaker: NSObject, ObservableObject {
  @Published private(set) var isSpeaking: Bool = false

  private let synthesizer = AVSpeechSynthesizer()
  private var onFinish: (() -> Void)?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  /// Configure AVAudioSession so playback routes through Bluetooth A2DP
  /// (i.e. glasses speakers when connected). Idempotent.
  func prepareAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playback,
      mode: .spokenAudio,
      options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers]
    )
    try session.setActive(true, options: .notifyOthersOnDeactivation)
  }

  func speak(_ text: String, onFinish: (() -> Void)? = nil) {
    self.onFinish = onFinish
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    utterance.pitchMultiplier = 1.0
    utterance.volume = 1.0
    isSpeaking = true
    synthesizer.speak(utterance)
  }

  func stop() {
    guard synthesizer.isSpeaking else { return }
    synthesizer.stopSpeaking(at: .immediate)
    isSpeaking = false
  }
}

extension LoreSpeaker: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      self.isSpeaking = false
      let cb = self.onFinish
      self.onFinish = nil
      cb?()
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      self.isSpeaking = false
      self.onFinish = nil
    }
  }
}
