---
description: Build the Lore Xcode project for iOS Simulator or a physical device
---

Build the Lore Xcode project.

## Prerequisites

- Xcode 16+
- iOS 17.0+ deployment target
- Meta Wearables DAT SDK wired via SPM (already configured in `Lore.xcodeproj`)

## Build (simulator)

From the project root (`Lore/`):

```bash
xcodebuild -project Lore.xcodeproj -scheme Lore -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Simulator works for mock flows (MockDeviceKit menu), but not for real glasses streaming or A2DP TTS-to-glasses.

## Run on device

To test the full capture → OpenRouter → glasses-speaker path you need physical hardware:

```bash
xcodebuild -project Lore.xcodeproj -scheme Lore \
  -destination 'platform=iOS,id=YOUR_DEVICE_UDID' build
```

Or just hit Cmd+R in Xcode after picking your device.

## Common build issues

- **Missing package**: Xcode > File > Add Package Dependencies > `https://github.com/facebook/meta-wearables-dat-ios`.
- **Signing**: in *Signing & Capabilities*, pick your own development team. Bundle id is currently `com.savargupta.lore`.
- **Minimum deployment target**: the project and SwiftData both require iOS 17+.
- **Entitlements**: `bluetooth-peripheral`, `external-accessory`, and the `MWDAT` Info.plist block are already set up — don't remove them.
