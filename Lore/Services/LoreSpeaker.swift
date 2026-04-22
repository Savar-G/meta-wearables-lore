import AVFoundation
import Foundation

@MainActor
final class LoreSpeaker: NSObject, ObservableObject {
  @Published private(set) var isSpeaking: Bool = false

  private let synthesizer = AVSpeechSynthesizer()
  private var onFinish: (() -> Void)?

  /// Rolling buffer of streamed tokens that haven't yet formed a complete
  /// sentence. We flush it into the synthesizer as soon as a sentence
  /// terminator arrives, and again when the stream ends.
  private var streamBuffer: String = ""

  /// True between `beginStream()` and `markStreamComplete()`. Used to
  /// distinguish "the stream ended and the tail should be spoken even
  /// without a terminator" from "a new word just arrived mid-stream".
  private var isStreamActive: Bool = false

  /// Number of utterances we've handed to the synthesizer that haven't
  /// finished yet. When this hits zero AFTER the stream is complete, we
  /// fire `onFinish`. Prevents the one-shot `speak(_:)` API from regressing
  /// while adding streaming support alongside it.
  private var pendingUtterances: Int = 0

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  /// Configure AVAudioSession so playback routes through Bluetooth A2DP
  /// (i.e. glasses speakers when connected). Idempotent.
  ///
  /// We intentionally do NOT enable HFP (`.allowBluetoothHFP`, formerly
  /// `.allowBluetooth`). HFP is narrow-band phone-call quality; we want
  /// stereo media playback via A2DP only. With `.playback` + A2DP, iOS
  /// routes to the glasses speakers whenever they're the active BT route.
  func prepareAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playback,
      mode: .spokenAudio,
      options: [.allowBluetoothA2DP, .duckOthers]
    )
    try session.setActive(true, options: .notifyOthersOnDeactivation)
  }

  // MARK: - One-shot API (non-streaming path)

  func speak(_ text: String, onFinish: (() -> Void)? = nil) {
    stop()
    self.onFinish = onFinish
    enqueueUtterance(text)
  }

  // MARK: - Streaming API

  /// Open a new streaming session. Any queued utterances from a prior
  /// stream are cancelled. Call `enqueue(_:)` as tokens arrive, then
  /// `markStreamComplete()` when the upstream closes.
  func beginStream(onFinish: (() -> Void)? = nil) {
    stop()
    self.onFinish = onFinish
    streamBuffer = ""
    isStreamActive = true
  }

  /// Append a token fragment. If the buffer now ends in sentence-terminating
  /// punctuation followed by whitespace (or whitespace is implied by the
  /// next incoming token), flush the complete sentence(s) to the synthesizer
  /// so playback can begin before the full response is generated.
  func enqueue(_ fragment: String) {
    guard isStreamActive else { return }
    streamBuffer.append(fragment)

    // Pull off as many complete sentences as the buffer currently contains.
    // "Complete" = ends with ., ?, or ! followed by whitespace. We keep the
    // trailing remainder in the buffer for the next call.
    while let sentenceEnd = nextSentenceBoundary(in: streamBuffer) {
      let sentence = String(streamBuffer[..<sentenceEnd])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      streamBuffer = String(streamBuffer[sentenceEnd...])
      if !sentence.isEmpty {
        enqueueUtterance(sentence)
      }
    }
  }

  /// The upstream closed. Flush any remaining buffered text as a final
  /// utterance, then arm the onFinish callback to fire when the last
  /// utterance finishes playing.
  func markStreamComplete() {
    guard isStreamActive else { return }
    isStreamActive = false

    let tail = streamBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    streamBuffer = ""
    if !tail.isEmpty {
      enqueueUtterance(tail)
    }

    // If nothing was ever enqueued, fire onFinish immediately so callers
    // don't hang. (Empty stream = nothing to speak.)
    if pendingUtterances == 0 {
      let cb = onFinish
      onFinish = nil
      cb?()
    }
  }

  func stop() {
    isStreamActive = false
    streamBuffer = ""
    pendingUtterances = 0
    onFinish = nil
    guard synthesizer.isSpeaking else { return }
    synthesizer.stopSpeaking(at: .immediate)
    isSpeaking = false
  }

  // MARK: - Private

  private func enqueueUtterance(_ text: String) {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    utterance.pitchMultiplier = 1.0
    utterance.volume = 1.0
    pendingUtterances += 1
    isSpeaking = true
    synthesizer.speak(utterance)
  }

  /// Returns an index pointing just past a sentence terminator followed by
  /// whitespace, or nil if no complete sentence is available yet. Treats
  /// common abbreviations conservatively — we only split if the period is
  /// followed by whitespace AND the next non-whitespace char is uppercase
  /// or the string has ended there.
  private func nextSentenceBoundary(in text: String) -> String.Index? {
    let terminators: Set<Character> = [".", "?", "!"]
    var i = text.startIndex
    while i < text.endIndex {
      if terminators.contains(text[i]) {
        let afterTerminator = text.index(after: i)
        if afterTerminator == text.endIndex { return nil }  // wait for more
        let next = text[afterTerminator]
        if next.isWhitespace {
          // Look at the next non-whitespace to reduce "Dr. Smith" style
          // false splits. If none yet, wait.
          var scan = afterTerminator
          while scan < text.endIndex, text[scan].isWhitespace {
            scan = text.index(after: scan)
          }
          if scan == text.endIndex { return nil }
          let nextChar = text[scan]
          // Accept uppercase, digit, or quote as plausible sentence starts.
          if nextChar.isUppercase || nextChar.isNumber || nextChar == "\"" || nextChar == "\u{201C}" {
            return afterTerminator  // include the terminator, drop leading ws
          }
        }
      }
      i = text.index(after: i)
    }
    return nil
  }
}

extension LoreSpeaker: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      self.pendingUtterances = max(0, self.pendingUtterances - 1)
      // Only flip isSpeaking off when the queue is fully drained.
      if self.pendingUtterances == 0 {
        self.isSpeaking = false
        // If a stream is still active, more sentences may still be coming —
        // don't fire onFinish yet. Fire only after markStreamComplete().
        if !self.isStreamActive {
          let cb = self.onFinish
          self.onFinish = nil
          cb?()
        }
      }
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      self.pendingUtterances = max(0, self.pendingUtterances - 1)
      if self.pendingUtterances == 0 {
        self.isSpeaking = false
        self.onFinish = nil
      }
    }
  }
}
