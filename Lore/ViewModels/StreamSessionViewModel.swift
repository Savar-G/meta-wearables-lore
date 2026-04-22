/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Combine
import MWDATCamera
import MWDATCore
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

/// ViewModel for video streaming UI. Delegates device management to DeviceSessionManager.
@MainActor
final class StreamSessionViewModel: ObservableObject {
  // MARK: - Published State

  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""

  @Published var capturedPhoto: UIImage?
  @Published var showPhotoCaptureError: Bool = false
  @Published var photoCaptureErrorMessage: String = ""
  @Published var isCapturingPhoto: Bool = false

  /// True when the capture button should be tappable — stream is live and
  /// no prior capture is still in flight.
  var canCapturePhoto: Bool {
    streamingStatus == .streaming && !isCapturingPhoto
  }

  @Published var hasActiveDevice: Bool = false
  @Published var isDeviceSessionReady: Bool = false

  // Lore pipeline state — exposed for the overlay UI
  @Published var loreState: LoreFlowState = .idle
  /// True when the user can ask a follow-up ("Tell me more"). Flips on when
  /// the initial lore finishes, stays on until max depth is reached or the
  /// conversation is dismissed. Published so SwiftUI can show/hide the
  /// button without the VM manually invalidating state.
  @Published var canFollowUp: Bool = false
  let loreSpeaker = LoreSpeaker()
  let locationProvider = LoreLocationProvider()

  /// Journal persistence. Optional because the VM is constructed before
  /// SwiftData's ModelContext is available in the view hierarchy — the
  /// view attaches this in `.task`. Nil means "running without journal"
  /// (e.g., unit tests) and `finalizeAssistantTurn` simply won't save.
  var journalStore: JournalStore?

  var isStreaming: Bool { streamingStatus != .stopped }

  // MARK: - Private

  private let sessionManager: DeviceSessionManager
  private let wearables: WearablesInterface
  private var streamSession: StreamSession?
  private var cancellables = Set<AnyCancellable>()
  private let loreService = LoreService()
  private var lastPhotoData: Data?
  private var activeLoreTask: Task<Void, Never>?

  /// Ring buffer of the most-recent video frames. On capture, we score
  /// these with `FrameSharpness` and send the sharpest into the lore
  /// pipeline immediately — the glasses' `capturePhoto()` roundtrip can
  /// add 400-1000ms of latency we don't actually need for the vision
  /// model (which resizes to ~1024px internally anyway).
  private var recentFrames: [UIImage] = []
  private static let recentFramesCapacity = 5

  /// True once we've kicked off lore for the current capture from a
  /// video frame. Prevents `handlePhotoData` from re-running the pipeline
  /// when the high-resolution photo eventually arrives.
  private var loreStartedFromFrame: Bool = false

  /// Running message history for the current capture. The first two
  /// entries are the system prompt and the user's image turn; follow-ups
  /// append alternating user/assistant text messages. Reset on each new
  /// `runLorePipeline(with:)` call.
  private var conversationHistory: [LoreMessage] = []
  private var followUpCount: Int = 0
  private static let maxFollowUps: Int = 3
  /// Fixed text for a "Tell me more" follow-up. Kept short and directive —
  /// the model already has the image + first answer in context, so we
  /// don't need to re-explain the task.
  private static let followUpPrompt =
    "Tell me more. Go deeper — another angle, another detail most tourists miss. Stay in character."

  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?

  /// Recovers `isCapturingPhoto` if `photoDataPublisher` never fires.
  /// Without this, one silent SDK drop locks the button permanently.
  private var captureTimeoutTask: Task<Void, Never>?
  private static let captureTimeoutSeconds: UInt64 = 8

  // MARK: - Init

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.sessionManager = DeviceSessionManager(wearables: wearables)

    // Forward session manager state to this ViewModel for SwiftUI binding
    sessionManager.$hasActiveDevice
      .receive(on: DispatchQueue.main)
      .assign(to: &$hasActiveDevice)
    sessionManager.$isReady
      .receive(on: DispatchQueue.main)
      .assign(to: &$isDeviceSessionReady)
  }

  // MARK: - Public API

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      var status = try await wearables.checkPermissionStatus(permission)
      if status != .granted {
        status = try await wearables.requestPermission(permission)
      }
      guard status == .granted else {
        showError("Permission denied")
        return
      }
      // Fire location off in parallel with the SDK start. This is a soft
      // ask — if the user denies, the pipeline still works, just without
      // place-grounded context lines. We don't block streaming on it.
      locationProvider.start()
      await startSession()
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func stopSession() async {
    guard let stream = streamSession else { return }
    streamSession = nil
    clearListeners()
    captureTimeoutTask?.cancel()
    captureTimeoutTask = nil
    isCapturingPhoto = false
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    recentFrames.removeAll()
    loreStartedFromFrame = false
    conversationHistory.removeAll()
    followUpCount = 0
    canFollowUp = false
    locationProvider.stop()
    await stream.stop()
  }

  func capturePhoto() {
    // Each failure path gets a specific message so console + alert tell us
    // exactly which guard tripped. Generic "something went wrong" copy is
    // useless for debugging on hardware.
    if isCapturingPhoto {
      NSLog("[Lore] capturePhoto blocked: prior capture still in flight")
      photoCaptureErrorMessage =
        "A capture is already in progress. Give it a second."
      showPhotoCaptureError = true
      return
    }
    guard streamingStatus == .streaming else {
      NSLog("[Lore] capturePhoto blocked: streamingStatus=\(streamingStatus)")
      photoCaptureErrorMessage =
        "The stream isn't ready yet. Wait for the preview to appear, then try again."
      showPhotoCaptureError = true
      return
    }
    guard let session = streamSession else {
      NSLog("[Lore] capturePhoto blocked: streamSession is nil")
      photoCaptureErrorMessage =
        "No active stream. Stop and restart streaming."
      showPhotoCaptureError = true
      return
    }

    isCapturingPhoto = true
    loreStartedFromFrame = false
    let accepted = session.capturePhoto(format: .jpeg)
    if !accepted {
      NSLog("[Lore] capturePhoto(format: .jpeg) returned false")
      isCapturingPhoto = false
      photoCaptureErrorMessage =
        "The glasses refused the capture request. This is usually low storage on the device or a transient hardware hiccup — try again."
      showPhotoCaptureError = true
      return
    }

    // Kick off lore immediately against the sharpest recent video frame.
    // This buys us the ~400-1000ms the glasses would otherwise spend
    // capturing + uploading the full-res JPEG. The high-res photo still
    // arrives via `photoDataPublisher` and gets stored for the journal,
    // but it doesn't re-trigger the pipeline (see handlePhotoData).
    if let frameJPEG = bestRecentFrameJPEG() {
      loreStartedFromFrame = true
      lastPhotoData = frameJPEG  // Seed retry in case real photo fails to arrive.
      runLorePipeline(with: frameJPEG)
    } else {
      NSLog("[Lore] No recent frames available; waiting for capturePhoto roundtrip")
    }

    startCaptureTimeout()
  }

  /// If `photoDataPublisher` doesn't fire within `captureTimeoutSeconds`,
  /// reset `isCapturingPhoto` and surface a diagnostic. Keeps the button
  /// from ever getting permanently stuck.
  private func startCaptureTimeout() {
    captureTimeoutTask?.cancel()
    captureTimeoutTask = Task { [weak self] in
      try? await Task.sleep(
        nanoseconds: Self.captureTimeoutSeconds * 1_000_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, self.isCapturingPhoto else { return }
        NSLog("[Lore] capture timed out after \(Self.captureTimeoutSeconds)s — no photo data received")
        self.isCapturingPhoto = false
        self.photoCaptureErrorMessage =
          "The glasses accepted the capture but no photo came back. This can happen after a thermal or connectivity hiccup. Try again — if it keeps happening, stop and restart the stream."
        self.showPhotoCaptureError = true
      }
    }
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func dismissPhotoCaptureError() {
    showPhotoCaptureError = false
  }

  func dismissLore() {
    activeLoreTask?.cancel()
    activeLoreTask = nil
    loreSpeaker.stop()
    loreState = .idle
    conversationHistory.removeAll()
    followUpCount = 0
    canFollowUp = false
  }

  func retryLore() {
    guard let data = lastPhotoData else {
      loreState = .idle
      return
    }
    runLorePipeline(with: data)
  }

  // MARK: - Private

  private func startSession() async {
    guard let deviceSession = await sessionManager.getSession() else { return }
    guard deviceSession.state == .started else { return }

    // Stream-quality tuning notes (see .claude/skills/camera-streaming.md):
    // - Resolution enum: .high 720x1280, .medium 504x896, .low 360x640.
    // - Valid frame rates: 2, 7, 15, 24, 30.
    // - The SDK auto-downgrades resolution (then frame rate) when the BT
    //   link can't sustain the request. So "request lower settings for
    //   higher per-frame quality" — .medium is a sweet spot: 2x the pixels
    //   of .low without triggering aggressive BT compression.
    // - Codec: stick to .raw. VideoFrame.makeUIImage() is built for the raw
    //   path; .hvc1 ships HEVC-encoded CMSampleBuffers that the helper
    //   doesn't decode, which produced a black preview in testing.
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.medium,
      frameRate: 24
    )

    let stream: StreamSession?
    do {
      stream = try deviceSession.addStream(config: config)
    } catch {
      NSLog("[Lore] addStream failed: \(error)")
      showError("Could not start stream: \(error.localizedDescription)")
      return
    }
    guard let stream else {
      NSLog("[Lore] addStream returned nil for config \(config)")
      showError("Stream unavailable for this device. Try reconnecting.")
      return
    }
    streamSession = stream
    streamingStatus = .waiting
    setupListeners(for: stream)
    await stream.start()
  }

  private func setupListeners(for stream: StreamSession) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStateChange(state) }
    }

    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      Task { @MainActor in self?.handleVideoFrame(frame) }
    }

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleError(error) }
    }

    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.handlePhotoData(data) }
    }
  }

  private func clearListeners() {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  private func handleStateChange(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func handleVideoFrame(_ frame: VideoFrame) {
    if let image = frame.makeUIImage() {
      currentVideoFrame = image
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
      }
      recentFrames.append(image)
      if recentFrames.count > Self.recentFramesCapacity {
        recentFrames.removeFirst(recentFrames.count - Self.recentFramesCapacity)
      }
    }
  }

  /// Pick the sharpest frame in the ring buffer and encode as JPEG.
  /// Returns nil if the buffer is empty or encoding fails.
  private func bestRecentFrameJPEG() -> Data? {
    guard !recentFrames.isEmpty else { return nil }
    let best = recentFrames.max { lhs, rhs in
      FrameSharpness.score(lhs) < FrameSharpness.score(rhs)
    } ?? recentFrames.last
    return best?.jpegData(compressionQuality: 0.85)
  }

  private func handleError(_ error: StreamSessionError) {
    let message = formatError(error)
    if message != errorMessage {
      showError(message)
    }
  }

  private func handlePhotoData(_ data: PhotoData) {
    captureTimeoutTask?.cancel()
    captureTimeoutTask = nil
    isCapturingPhoto = false
    capturedPhoto = UIImage(data: data.data)
    // Upgrade the retry source to the full-res photo now that it's here.
    lastPhotoData = data.data

    // If we already started lore from a video frame, don't restart —
    // that would cancel the in-flight response and double the latency.
    // The full-res photo is kept for any later journaling / retry.
    if loreStartedFromFrame {
      loreStartedFromFrame = false
      return
    }
    runLorePipeline(with: data.data)
  }

  private func runLorePipeline(with jpegData: Data) {
    // Fresh conversation — reset history and follow-up depth. Any prior
    // "Tell me more" chain belongs to the previous capture.
    let systemPrompt = LoreSecrets.persona.systemPrompt(
      contextLines: locationProvider.contextLines
    )
    conversationHistory = [
      .system(systemPrompt),
      .user(jpegData: jpegData, text: LoreConfig.userPrompt),
    ]
    followUpCount = 0
    canFollowUp = false
    runPipeline(messages: conversationHistory)
  }

  /// Kicks off the streaming/non-streaming pipeline for the current
  /// `conversationHistory`. Used both for the initial capture and for
  /// follow-up turns — the shape of the request is the same either way.
  private func runPipeline(messages: [LoreMessage]) {
    activeLoreTask?.cancel()
    loreSpeaker.stop()
    loreState = .thinking
    // Hide the follow-up affordance while a new turn is in-flight. It
    // re-enables on completion if we haven't hit maxFollowUps.
    canFollowUp = false

    // Prepare audio session up front so the first utterance doesn't pay the
    // category-activation latency. Failures here are logged but non-fatal —
    // TTS will still attempt to play on the default route.
    do {
      try loreSpeaker.prepareAudioSession()
    } catch {
      NSLog("[Lore] Audio session setup failed: \(error)")
    }

    if LoreConfig.useStreaming {
      activeLoreTask = Task { [loreService, loreSpeaker] in
        await self.runStreamingPipeline(
          messages: messages,
          loreService: loreService,
          loreSpeaker: loreSpeaker
        )
      }
    } else {
      activeLoreTask = Task { [loreService, loreSpeaker] in
        await self.runNonStreamingPipeline(
          messages: messages,
          loreService: loreService,
          loreSpeaker: loreSpeaker
        )
      }
    }
  }

  /// User tapped "Tell me more". Appends a follow-up user turn to the
  /// history and re-runs the pipeline. No-op if `canFollowUp` is false
  /// (i.e., no current lore, mid-stream, or max depth reached).
  func askFollowUp() {
    guard canFollowUp else { return }
    guard followUpCount < Self.maxFollowUps else {
      canFollowUp = false
      return
    }
    // Any prior assistant response is already appended by the completion
    // handlers below, so the history is ready to accept a user turn.
    conversationHistory.append(.user(Self.followUpPrompt))
    followUpCount += 1
    runPipeline(messages: conversationHistory)
  }

  /// SSE path. Starts TTS on the first full sentence, so time-to-first-word
  /// is driven by model latency, not model completion.
  private func runStreamingPipeline(
    messages: [LoreMessage],
    loreService: LoreService,
    loreSpeaker: LoreSpeaker
  ) async {
    // When the speaker drains its last utterance AFTER the stream completes,
    // flip the overlay to .finished with the accumulated transcript.
    let transcript = TranscriptBox()
    loreSpeaker.beginStream { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        let text = await transcript.read()
        if case .speaking = self.loreState {
          self.loreState = .finished(text)
        } else if case .thinking = self.loreState, !text.isEmpty {
          self.loreState = .finished(text)
        }
        self.finalizeAssistantTurn(text: text)
      }
    }

    do {
      for try await delta in loreService.streamLoreChat(messages: messages) {
        if Task.isCancelled { break }
        await transcript.append(delta)
        let running = await transcript.read()
        await MainActor.run {
          // Flip to .speaking on the first token so the overlay shows the
          // text building in real time.
          self.loreState = .speaking(running)
        }
        loreSpeaker.enqueue(delta)
      }

      if Task.isCancelled {
        loreSpeaker.stop()
        return
      }
      loreSpeaker.markStreamComplete()
    } catch is CancellationError {
      loreSpeaker.stop()
      return
    } catch {
      if Task.isCancelled { return }
      loreSpeaker.stop()
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      await MainActor.run {
        self.loreState = .error(message)
      }
    }
  }

  /// Legacy one-shot path, kept behind `LoreConfig.useStreaming = false` so
  /// we can A/B if the SSE path misbehaves on a specific model.
  private func runNonStreamingPipeline(
    messages: [LoreMessage],
    loreService: LoreService,
    loreSpeaker: LoreSpeaker
  ) async {
    do {
      let text = try await loreService.loreChat(messages: messages)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self.loreState = .speaking(text)
      }
      loreSpeaker.speak(text) { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          if case .speaking(let current) = self.loreState {
            self.loreState = .finished(current)
          }
          self.finalizeAssistantTurn(text: text)
        }
      }
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      await MainActor.run {
        self.loreState = .error(message)
      }
    }
  }

  /// Called once per turn after the assistant's response has fully
  /// streamed (or the non-streaming call returned). Appends the assistant
  /// message to `conversationHistory`, persists the capture on the first
  /// turn, and re-enables the follow-up button if we're under the depth
  /// cap. Centralized here so the streaming + non-streaming paths can't
  /// drift.
  private func finalizeAssistantTurn(text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    conversationHistory.append(.assistant(trimmed))
    canFollowUp = followUpCount < Self.maxFollowUps

    // Only persist on the FIRST assistant turn. Follow-ups are the same
    // story from another angle; they shouldn't spawn new journal entries.
    // `followUpCount` is incremented BEFORE the follow-up pipeline runs,
    // so the first response always sees it as 0.
    if followUpCount == 0, let store = journalStore, let photo = lastPhotoData {
      store.save(
        transcript: trimmed,
        persona: LoreSecrets.persona,
        languageCode: nil,  // Populated in Phase 4 once language picker lands.
        photoJPEG: photo,
        placemark: locationProvider.placemark
      )
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  /// Tiny actor that accumulates streamed tokens. Using an actor rather than
  /// a `var String` avoids data races between the SSE consumer and the
  /// speaker's `onFinish` callback that reads the final transcript.
  private actor TranscriptBox {
    private var buffer: String = ""
    func append(_ fragment: String) { buffer.append(fragment) }
    func read() -> String { buffer }
  }

  private func formatError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    case .thermalCritical:
      return "Device is overheating. Streaming has been paused to protect the device."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
