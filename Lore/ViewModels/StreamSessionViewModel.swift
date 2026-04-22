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
  @Published var isCapturingPhoto: Bool = false

  @Published var hasActiveDevice: Bool = false
  @Published var isDeviceSessionReady: Bool = false

  // Lore pipeline state — exposed for the overlay UI
  @Published var loreState: LoreFlowState = .idle
  let loreSpeaker = LoreSpeaker()

  var isStreaming: Bool { streamingStatus != .stopped }

  // MARK: - Private

  private let sessionManager: DeviceSessionManager
  private let wearables: WearablesInterface
  private var streamSession: StreamSession?
  private var cancellables = Set<AnyCancellable>()
  private let loreService = LoreService()
  private var lastPhotoData: Data?
  private var activeLoreTask: Task<Void, Never>?

  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?

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
      await startSession()
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func stopSession() async {
    guard let stream = streamSession else { return }
    streamSession = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    await stream.stop()
  }

  func capturePhoto() {
    guard !isCapturingPhoto, streamingStatus == .streaming else {
      showPhotoCaptureError = true
      return
    }
    isCapturingPhoto = true
    let success = streamSession?.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showPhotoCaptureError = true
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
    }
  }

  private func handleError(_ error: StreamSessionError) {
    let message = formatError(error)
    if message != errorMessage {
      showError(message)
    }
  }

  private func handlePhotoData(_ data: PhotoData) {
    isCapturingPhoto = false
    capturedPhoto = UIImage(data: data.data)
    lastPhotoData = data.data
    runLorePipeline(with: data.data)
  }

  private func runLorePipeline(with jpegData: Data) {
    activeLoreTask?.cancel()
    loreSpeaker.stop()
    loreState = .thinking

    activeLoreTask = Task { [loreService, loreSpeaker] in
      do {
        let text = try await loreService.lore(forJPEG: jpegData)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self.loreState = .speaking(text)
        }
        do {
          try loreSpeaker.prepareAudioSession()
        } catch {
          NSLog("[Lore] Audio session setup failed: \(error)")
        }
        loreSpeaker.speak(text) { [weak self] in
          Task { @MainActor in
            guard let self else { return }
            if case .speaking(let current) = self.loreState {
              self.loreState = .finished(current)
            }
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
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
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
