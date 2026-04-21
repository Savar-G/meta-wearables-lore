# Lore

> Point at anything. Learn something cool.

iOS companion app for Meta Ray-Ban smart glasses that speaks a short, surprising fun-fact about whatever you're looking at.

## How it works

1. Open Lore on iPhone, register with Meta AI, pair your glasses
2. Tap **Capture** — the glasses photograph whatever you're looking at
3. The image is sent to Claude Vision, which returns a genuinely interesting fun-fact
4. The fact is spoken back through your glasses speakers

## Stack

- iOS (SwiftUI)
- [Meta Wearables Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios) v0.6.0
- Claude Vision API
- `AVSpeechSynthesizer` over A2DP for glasses-speaker TTS

## Requirements

- Xcode 15.0+
- iOS 17.0+ target device (or Simulator + MockDeviceKit for dev)
- Ray-Ban Meta or Meta Ray-Ban Display glasses
- Meta AI companion app with **Developer Mode** enabled (Settings → Your glasses → Developer Mode)
- An Anthropic API key (see [Setup](#setup))

## Setup

1. **Clone** this repo
2. **Open** `Lore.xcodeproj` in Xcode
3. **Add SDK:** File → Add Package Dependencies → `https://github.com/facebook/meta-wearables-dat-ios`
4. **Signing:** set your development team in Signing & Capabilities
5. **API key:** copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and add your Anthropic API key (file is gitignored)
6. **Build & run** on a physical device for real-hardware testing, or use the debug menu to simulate a device with MockDeviceKit

## Running with mock hardware

In Debug builds, the app ships with a mock-device menu so you can iterate without glasses. Tap the debug button, pair a mock Ray-Ban Meta, set a test image, and go.

## Development notes

This project was forked from Meta's `CameraAccess` sample. See `CLAUDE.md` for project conventions and AI assistant instructions.

## License

Original CameraAccess code © Meta Platforms, Inc., under the license in `NOTICE`. Lore modifications © 2026 Savar Gupta.
