# Lore

> Point at anything. Learn something cool.

iOS companion app for Meta Ray-Ban smart glasses that captures what you're looking at, asks a vision model *"what's the lore behind this?"*, and speaks a short, surprising fact back through the glasses speakers.

This is a portfolio build on top of Meta's public [Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios) (DAT v0.6.0 developer preview). It's not affiliated with or endorsed by Meta.

## How it works

1. Open Lore on iPhone, register with Meta AI, pair your glasses.
2. Enter your OpenRouter API key once in **Settings → Lore settings** and pick a vision model.
3. Start streaming → tap the camera button. The glasses capture whatever you're looking at.
4. The JPEG is sent to OpenRouter's chat-completions endpoint with a system prompt that asks for one genuinely interesting fun-fact in under 20 seconds of speech.
5. The response is spoken via `AVSpeechSynthesizer`, routed to the glasses through an `AVAudioSession` configured for A2DP Bluetooth.

An on-screen overlay shows the pipeline state: *Looking up the lore…* → *Lore* (with the text) → *Done*, plus a retry affordance if the API call fails.

## Stack

- **iOS 17+ / SwiftUI** — forked from Meta's `CameraAccess` sample app
- **[Meta Wearables DAT](https://github.com/facebook/meta-wearables-dat-ios) v0.6.0** — `MWDATCore`, `MWDATCamera`, `MWDATMockDevice`
- **[OpenRouter](https://openrouter.ai)** — any vision-capable model. Default `anthropic/claude-sonnet-4.6`; also configurable to Opus 4.7, Haiku 4.5, GPT-4o, or Gemini 2.5 Pro/Flash
- **`AVSpeechSynthesizer`** over A2DP for glasses-speaker TTS

## Requirements

- Xcode 16+
- iOS 17.0+ physical device for hardware testing (Simulator works for Mock flows, but not for real streaming/TTS-to-glasses)
- Ray-Ban Meta or Meta Ray-Ban Display glasses
- Meta AI companion app with **Developer Mode** enabled (Settings → Your glasses → Developer Mode)
- An OpenRouter API key ([openrouter.ai](https://openrouter.ai))

## Setup

1. **Clone** this repo.
2. **Open** `Lore.xcodeproj` in Xcode. The DAT SDK is already wired as a Swift Package dependency — Xcode will resolve it on first open.
3. **Signing:** in *Signing & Capabilities*, pick your own development team and confirm the bundle identifier (currently `com.savargupta.lore`).
4. **Build & run** on a physical device.
5. **Configure the API key in-app:** tap the gear icon on the home screen → *Lore settings* → paste your OpenRouter key → pick a model → *Save*. The key is stored in `UserDefaults` via `LoreSecrets` (Keychain migration is a known TODO).

> The key never leaves the device except in `Authorization` headers bound for `https://openrouter.ai/api/v1/chat/completions`.

## Running with mock hardware

Debug builds expose a *MockDeviceKit* menu so you can iterate without pairing real glasses. Launch the app → open the debug menu → pair a mock Ray-Ban Meta → set a test image → start streaming → tap the camera button. The rest of the pipeline (OpenRouter → TTS) runs as usual, which is useful for iterating on prompt design and UI state.

## Code layout

```
Lore/
  Services/
    LoreConfig.swift     — base URL, default + available models, system prompt
    LoreSecrets.swift    — api-key + model persistence (UserDefaults; Keychain TODO)
    LoreService.swift    — OpenRouter client: lore(forJPEG:) -> String
    LoreSpeaker.swift    — AVSpeechSynthesizer + AVAudioSession (A2DP) wrapper
  ViewModels/
    StreamSessionViewModel.swift  — orchestrates capture → lore → speak; exposes LoreFlowState
    …
  Views/
    LoreSettingsView.swift  — in-app API-key + model Picker sheet
    LoreOverlayView.swift   — HUD bubbles driven by LoreFlowState
    StreamView.swift        — live stream, capture button, gear button, overlay
    NonStreamView.swift     — pre-stream home with gear + disconnect menu
    …
```

`StreamSessionViewModel.runLorePipeline(with:)` is the single pipeline entry point. It cancels any in-flight run, flips `loreState` through `.thinking` → `.speaking` → `.finished`, and catches errors into `.error` with a retry path.

## Known gaps

- **"Hey Meta" voice trigger is not in the public SDK.** The hardware capture button on the glasses routes to Meta AI, not third-party apps. MVP uses an in-app capture button; a voice-first flow is a future feature contingent on Meta exposing intent registration. Tracked via [Meta's DAT discussions](https://github.com/facebook/meta-wearables-dat-ios/discussions).
- **Streaming TTS.** End-to-end capture → OpenRouter → TTS can feel slow (~2–4s). A future iteration can stream the chat completion and start speaking on the first sentence.
- **Keychain migration.** `LoreSecrets` currently writes to `UserDefaults`. Move to Keychain before shipping outside a portfolio context.

## License

The app forks Meta's `CameraAccess` sample, which is distributed under the [Meta Wearables Developer Terms](https://wearables.developer.meta.com/terms); see [`LICENSE`](LICENSE). Lore-specific modifications © 2026 Savar Gupta.

AI assistance disclosure: parts of this project were drafted with Claude (Anthropic) acting as a pair programmer. All code was reviewed and signed off by the author.
