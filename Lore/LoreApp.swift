/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// LoreApp.swift
//
// Main entry point for the Lore sample app demonstrating the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//

import Foundation
import MWDATCore
import SwiftData
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@main
struct LoreApp: App {
  #if DEBUG
  // Debug menu for simulating device connections during development
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif
  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel

  /// Shared SwiftData container for the Journal. Built once at launch so
  /// every view reads from the same store. Failure is fatal — if we can't
  /// persist captures, the Journal feature is effectively gone and users
  /// would lose work silently. Better to crash loud and fix it.
  private let modelContainer: ModelContainer = {
    let schema = Schema([JournalEntry.self, Trip.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    do {
      return try ModelContainer(for: schema, configurations: config)
    } catch {
      fatalError("[Lore] Failed to build ModelContainer: \(error)")
    }
  }()

  init() {
    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[Lore] Failed to configure Wearables SDK: \(error)")
      #endif
    }

    #if DEBUG
    // Auto-configure MockDeviceKit when launched by XCUITests
    if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
      MockDeviceKit.shared.enable()
      let device = MockDeviceKit.shared.pairRaybanMeta()

      let cameraKit = device.services.camera
      guard let videoURL = Bundle.main.url(forResource: "plant", withExtension: "mp4"),
        let imageURL = Bundle.main.url(forResource: "plant", withExtension: "png")
      else {
        fatalError("Test resources not found - are you running a Release build?")
      }
      cameraKit.setCameraFeed(fileURL: videoURL)
      cameraKit.setCapturedImage(fileURL: imageURL)

      device.powerOn()
      device.don()

    }
    #endif

    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      // Main app view with access to the shared Wearables SDK instance
      // The Wearables.shared singleton provides the core DAT API
      MainAppView(wearables: Wearables.shared, viewModel: wearablesViewModel)
        .modelContainer(modelContainer)
        // Show error alerts for view model failures
        .alert("Error", isPresented: $wearablesViewModel.showError) {
          Button("OK") {
            wearablesViewModel.dismissError()
          }
        } message: {
          Text(wearablesViewModel.errorMessage)
        }
        #if DEBUG
      .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
        MockDeviceKitView(viewModel: debugMenuViewModel.mockDeviceKitViewModel)
      }
      .overlay {
        DebugMenuView(debugMenuViewModel: debugMenuViewModel)
      }
        #endif

      // Registration view handles the flow for connecting to the glasses via Meta AI
      RegistrationView(viewModel: wearablesViewModel)
    }
  }
}
