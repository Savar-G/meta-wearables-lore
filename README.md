# Lore

> The travel guide that actually knows where you are, remembers where you've been, and tells stories worth listening to.

iOS companion app for Meta Ray-Ban smart glasses. Point at anything while you travel. A gifted narrator (or patient professor, or sharp-eyed skeptic) tells you the real story in your ear, in your language, grounded in where you're standing. Every moment lands in a local Journal you can scroll, map, search, and share.

Portfolio build on top of Meta's public [Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios) (DAT v0.6.0 developer preview). Not affiliated with or endorsed by Meta.

## What's inside

- **Streaming TTS with sub-second time-to-first-word.** Tap Capture, the model streams via OpenRouter SSE, `LoreSpeaker` splits on sentence boundaries and starts speaking as soon as the first sentence lands. The sharpest frame from a rolling buffer kicks off the pipeline immediately so the glasses' full-res photo roundtrip happens in parallel instead of on the critical path.
- **Three personas.** Narrator (travel storyteller), Professor (patient scholar, named sources), Skeptic (myth-buster). Picked once in Settings, switchable any time.
- **Location-grounded.** `LoreLocationProvider` feeds reverse-geocoded context lines ("User's approximate location: Barcelona, Catalonia, Spain. Likely nearby landmark: Sagrada Família.") into the system prompt. Fully optional. Denied permission or no GPS falls through to image-only lore with no error.
- **Follow-ups.** Tap "Tell me more" to go deeper without re-uploading the photo. Max depth 3 per moment so a single capture can't run up a token bill.
- **Journal.** Every capture persists to SwiftData with photo, transcript, place, persona, language. Auto-grouped into Trips (new country OR 5-day gap = new trip). Three views: Timeline, Map, Search. Tap any entry for detail + Replay (speaks it back in the original language).
- **Memory.** On the next capture, the last 3 entries from the current trip get slotted into the prompt so the model knows what you've already heard and finds new angles.
- **10 languages.** English, Spanish, French, German, Italian, Portuguese, Japanese, Mandarin, Hindi, Arabic. Native-name instruction in the prompt locks the model onto the target language; matched `AVSpeechSynthesisVoice` speaks it back; sentence-boundary detection recognizes `。？！` / `؟` / `۔` so streaming TTS still kicks in for non-Latin scripts.
- **Shareable cards.** From any Journal entry, tap Share. `ImageRenderer` rasterizes a dark 1080×-wide card (photo hero → location + transcript → "Told by Lore · persona · date" footer) at 3× scale, handed to `UIActivityViewController` for Instagram / Messages / Save to Photos.
- **Graceful offline.** When `URLError` says you're actually offline (not just slow), the error flips to a `wifi.slash` icon and tells you the Journal still works — your past trips don't need a network.

## How it works

1. Open Lore on iPhone, register with Meta AI, pair your glasses.
2. Pop Settings → paste your OpenRouter key, pick a vision model, pick a persona, pick a language.
3. Start streaming → tap the camera button.
4. Lore picks the sharpest recent frame, sends it to OpenRouter's chat completions endpoint (SSE stream) with a composed system prompt (persona rules + location + recent-journal-memory + language instruction), and starts speaking on the first complete sentence via `AVSpeechSynthesizer` over Bluetooth A2DP.
5. The full-res photo arrives a moment later and gets saved to the Journal alongside the transcript, persona, place, and language code. Trip resolution picks the right Trip (or makes a new one).
6. Tap "Tell me more" to go deeper. Dismiss to return to streaming. Open the Journal any time from the menu.

## Stack

- **iOS 17+ / SwiftUI** — forked from Meta's `CameraAccess` sample
- **[Meta Wearables DAT](https://github.com/facebook/meta-wearables-dat-ios) v0.6.0** — `MWDATCore`, `MWDATCamera`, `MWDATMockDevice`
- **[OpenRouter](https://openrouter.ai)** — any vision-capable model. Default `qwen/qwen3.6-plus`; also configurable to Claude Opus 4.7 / Sonnet 4.6 / Haiku 4.5, GPT-4o, Gemini 2.5 Pro/Flash. Uses SSE streaming via `URLSession.AsyncBytes.lines`.
- **SwiftData** — local Journal persistence (`JournalEntry`, `Trip`), external photo storage
- **CoreLocation + MapKit** — coarse-accuracy geocoding for prompt context + MapKit SwiftUI `Map` for the journal map view
- **`AVSpeechSynthesizer`** over A2DP for glasses-speaker TTS, per-language voice selection
- **Core Image** — Laplacian-variance frame sharpness scoring for latency-killing ring-buffer capture

## Requirements

- Xcode 16+
- iOS 17.0+ physical device for hardware testing (Simulator works for Mock flows, but not for real streaming/TTS-to-glasses)
- Ray-Ban Meta or Meta Ray-Ban Display glasses
- Meta AI companion app with **Developer Mode** enabled (Settings → Your glasses → Developer Mode)
- An OpenRouter API key ([openrouter.ai](https://openrouter.ai))
- Location permission is optional — grant it for place-grounded stories, skip it and the pipeline runs image-only

## Setup

1. **Clone** this repo.
2. **Open** `Lore.xcodeproj` in Xcode. The DAT SDK is already wired as a Swift Package dependency — Xcode resolves it on first open.
3. **Signing:** in *Signing & Capabilities*, pick your development team and confirm the bundle identifier (currently `com.savargupta.lore`).
4. **Build & run** on a physical device.
5. **Configure in-app:** tap the gear icon on the home screen → *Lore settings* → paste your OpenRouter key → pick a model, persona, and language → *Save*. The key is stored in `UserDefaults` via `LoreSecrets` (Keychain migration is a known TODO).

> The key never leaves the device except in `Authorization` headers bound for `https://openrouter.ai/api/v1/chat/completions`.

## Running with mock hardware

Debug builds expose a *MockDeviceKit* menu so you can iterate without pairing real glasses. Launch the app → open the debug menu → pair a mock Ray-Ban Meta → set a test image → start streaming → tap the camera button. The rest of the pipeline (OpenRouter → TTS → Journal save) runs as usual, which is useful for iterating on prompt design, personas, and UI state.

## Code layout

```
Lore/
  Models/
    JournalEntry.swift     — @Model: photo (external storage), transcript, persona, language, placemark
    Trip.swift             — @Model: auto-grouped travel session (new country OR 5-day gap)
  Services/
    LoreConfig.swift       — base URL, default + available models, token budget, streaming flag
    LoreSecrets.swift      — api-key + model + persona + language persistence (UserDefaults; Keychain TODO)
    LorePersona.swift      — Narrator / Professor / Skeptic, base prompts, systemPrompt(contextLines:language:)
    LoreLanguage.swift     — 10 languages with native-name prompt lines and AVSpeechSynthesisVoice codes
    LoreMessage.swift      — Swift-side conversation turn (system/user/assistant; text or image+text)
    LoreService.swift      — OpenRouter client, streamLoreChat(messages:) SSE, offline-aware errors
    LoreSpeaker.swift      — AVSpeechSynthesizer + AVAudioSession (A2DP), streaming sentence split, multilingual voice
    LoreLocationProvider.swift — CLLocationManager + CLGeocoder, throttled, context-line formatter
    FrameSharpness.swift   — Laplacian-variance scoring for the recent-frames ring buffer
    JournalStore.swift     — MainActor wrapper over ModelContext: save, resolveTrip, memoryContextLines
  ViewModels/
    StreamSessionViewModel.swift  — orchestrates capture → lore → speak → save; conversation history, trip memory injection
    …
  Views/
    LoreSettingsView.swift  — in-app Form: API key + model + persona + language
    LoreOverlayView.swift   — HUD bubbles driven by LoreFlowState; offline detection; "Tell me more" button
    JournalView.swift       — Timeline / Map / Search + JournalEntryDetailView with Replay
    LoreShareCard.swift     — 1080pt shareable card + ImageRenderer + ShareSheet (UIActivityViewController bridge)
    StreamView.swift        — live stream, capture button, gear button, lore overlay
    NonStreamView.swift     — pre-stream home with settings/journal/disconnect menu
    …
```

`StreamSessionViewModel.runLorePipeline(with:)` is the single pipeline entry. It builds the system prompt by layering persona rules + location context + journal memory, opens a new conversation, streams through `LoreService.streamLoreChat(messages:)`, pipes deltas into `LoreSpeaker`, and on first-turn completion calls `JournalStore.save(...)` so every moment lands in the Journal.

## Known gaps

- **"Hey Meta" voice trigger is not in the public SDK.** The hardware capture button on the glasses routes to Meta AI, not third-party apps. MVP uses an in-app capture button; a voice-first flow is a future feature contingent on Meta exposing intent registration. Tracked via [Meta's DAT discussions](https://github.com/facebook/meta-wearables-dat-ios/discussions).
- **Keychain migration.** `LoreSecrets` currently writes to `UserDefaults`. Move to Keychain before shipping outside a portfolio context.
- **Offline-first landmark database.** When you're offline, Lore currently points you at the Journal. A bundled SQLite of common landmarks + pre-computed facts would let new lore still happen in a tunnel or on a plane. Deferred to avoid shipping a 30 MB DB for V1.

## License

The app forks Meta's `CameraAccess` sample, which is distributed under the [Meta Wearables Developer Terms](https://wearables.developer.meta.com/terms); see [`LICENSE`](LICENSE). Lore-specific modifications © 2026 Savar Gupta.

AI assistance disclosure: parts of this project were drafted with Claude (Anthropic) acting as a pair programmer. All code was reviewed and signed off by the author.
