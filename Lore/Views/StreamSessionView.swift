/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//
//

import MWDATCore
import SwiftData
import SwiftUI

struct StreamSessionView: View {
  let wearables: WearablesInterface
  @ObservedObject private var wearablesViewModel: WearablesViewModel
  @StateObject private var viewModel: StreamSessionViewModel
  /// SwiftData's shared context, injected by `.modelContainer(...)` in
  /// LoreApp. Used to lazily attach a JournalStore to the VM so each
  /// capture gets persisted.
  @Environment(\.modelContext) private var modelContext

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    ZStack {
      if viewModel.isStreaming {
        // Full-screen video view with streaming controls
        StreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      } else {
        // Pre-streaming setup view with permissions and start button
        NonStreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      }
    }
    .task {
      // Idempotent. The VM keeps the store reference once attached so
      // subsequent view rebuilds don't wipe in-flight work.
      if viewModel.journalStore == nil {
        viewModel.journalStore = JournalStore(context: modelContext)
      }
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
    .alert("Photo capture failed", isPresented: $viewModel.showPhotoCaptureError) {
      Button("OK") {
        viewModel.dismissPhotoCaptureError()
      }
    } message: {
      Text(viewModel.photoCaptureErrorMessage.isEmpty
        ? "Couldn't capture the photo. Try again."
        : viewModel.photoCaptureErrorMessage)
    }
  }
}
