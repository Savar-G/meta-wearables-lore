/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling.
//

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel
  @State private var showSettings: Bool = false

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Video backdrop
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      // Top-right Settings button
      VStack {
        HStack {
          Spacer()
          Button {
            showSettings = true
          } label: {
            Image(systemName: "gearshape.fill")
              .font(.title3)
              .foregroundColor(.white)
              .padding(12)
              .background(Circle().fill(Color.black.opacity(0.55)))
          }
          .accessibilityIdentifier("settings_button")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        Spacer()
      }

      // Lore overlay + bottom controls
      VStack(spacing: 12) {
        Spacer()
        LoreOverlayView(
          state: viewModel.loreState,
          onDismiss: { viewModel.dismissLore() },
          onRetry: { viewModel.retryLore() }
        )
        ControlsView(viewModel: viewModel)
      }
      .padding(.all, 24)
    }
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
      }
    }
    .sheet(isPresented: $showSettings) {
      LoreSettingsView()
    }
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        Task {
          await viewModel.stopSession()
        }
      }

      // Photo button
      CircleButton(icon: "camera.fill", text: nil) {
        viewModel.capturePhoto()
      }
      .accessibilityIdentifier("capture_photo_button")
    }
  }
}
