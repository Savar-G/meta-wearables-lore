# Lore — Project Instructions for Claude

## Project context

**Lore** is a portfolio iOS companion app for Meta Ray-Ban smart glasses. Product framing: *"The travel guide that actually knows where you are, remembers where you've been, and tells stories worth listening to."*

The user taps a button in the iOS app while traveling, the glasses capture whatever they're looking at, and a gifted narrator (Narrator / Professor / Skeptic persona) tells the story in their ear — in their chosen language, grounded in where they're standing, remembering what they've already heard on this trip. Every moment lands in a local SwiftData Journal they can scroll, map, search, and share.

### One-line concept
> Point at anything while you travel. Hear the real story.

### Core flow
1. User opens Lore on iPhone, registers with Meta AI, pairs with glasses.
2. User pops Settings → pastes OpenRouter key → picks model + persona + language (once).
3. User taps the **Capture** button.
4. `StreamSessionViewModel.capturePhoto()` fires two things in parallel:
   - Sends `StreamSession.capturePhoto(format: .jpeg)` to the glasses (full-res photo arrives via `photoDataPublisher` later).
   - Picks the sharpest frame from `recentFrames` (Laplacian-variance score via `FrameSharpness`) and kicks off the lore pipeline *immediately* against that JPEG. This cuts the ~400-1000ms capture roundtrip off the critical path.
5. `runLorePipeline(with:)` composes the system prompt: `LoreSecrets.persona.systemPrompt(contextLines: locationLines + memoryLines, language: LoreSecrets.language)`. Context lines come from `LoreLocationProvider` (reverse-geocoded placemark) and `JournalStore.memoryContextLines(limit: 3)` (last 3 entries from the active trip). Language adds a native-name instruction line when non-English.
6. Pipeline calls `LoreService.streamLoreChat(messages:)` — SSE streaming via `URLSession.AsyncBytes.lines`. Deltas flow into `LoreSpeaker.enqueue(_:)` which splits on sentence boundaries and starts speaking on the first complete sentence (TTS begins well before the full response arrives).
7. On first-turn completion, `finalizeAssistantTurn(text:)` appends the assistant message to `conversationHistory`, flips `canFollowUp = true`, and calls `JournalStore.save(...)` with the transcript, persona, language code, sharpest JPEG, and current `CLPlacemark`.
8. The Journal view reflects the new entry automatically via SwiftData `@Query`.

### Follow-ups
Tap "Tell me more" in the overlay's `.finished` state. `askFollowUp()` appends a text-only user turn (`"Tell me more. Go deeper..."`) to `conversationHistory` and re-runs the same pipeline. No image re-upload — the vision model keeps it in context. Capped at `maxFollowUps = 3`. Follow-ups do NOT spawn new Journal entries (same story, different angle).

### Scope for MVP
- **Trigger:** in-app button only. The public Meta Wearables DAT SDK (v0.6.0 developer preview) does **not** expose custom voice-intent registration with "Hey Meta" — the hardware capture button routes to Meta's own app, not third-party apps. Treat voice-first UX as a future feature contingent on Meta exposing intents.
- **Audio output:** through glasses speakers via standard iOS `AVAudioSession` (`.playback` + `.spokenAudio` + `.allowBluetoothA2DP` + `.duckOthers`). HFP deliberately not enabled — we want stereo A2DP media playback, not narrowband phone-call quality.
- **Dev loop:** use `MWDATMockDevice` with a test image before touching hardware.
- **Storage:** SwiftData for Journal, UserDefaults for API key / model / persona / language. No backend; everything on device.

## Stack

- **iOS app:** SwiftUI, iOS 17+, forked from Meta's `samples/CameraAccess/` reference app
- **SDK:** Meta Wearables Device Access Toolkit (DAT) v0.6.0 via Swift Package Manager
  - Modules: `MWDATCore` (required), `MWDATCamera` (required), `MWDATMockDevice` (debug-only)
- **AI:** OpenRouter (any vision-capable model). Default `qwen/qwen3.6-plus`. Other options in `LoreConfig.availableModels` (Claude Opus 4.7 / Sonnet 4.6 / Haiku 4.5, GPT-4o, Gemini 2.5 Pro/Flash). SSE streaming when `LoreConfig.useStreaming = true` (the default).
- **Persistence:** SwiftData (`JournalEntry`, `Trip`) with `@Attribute(.externalStorage)` for photo blobs. UserDefaults for secrets via `LoreSecrets`. Keychain migration is a known TODO.
- **Location:** CoreLocation `.hundredMeters` accuracy, throttled geocoding (re-geocode only when user moved ≥100m OR ≥5 min elapsed).
- **TTS:** `AVSpeechSynthesizer` (built into iOS) with per-language voice selection routed through glasses via A2DP.
- **Mapping:** MapKit SwiftUI `Map` + `Annotation` for the Journal Map tab.
- **Share:** `ImageRenderer` (iOS 16+) rasterizes a SwiftUI card; `UIActivityViewController` handles the sheet.

### Lore pipeline code layout

```
Lore/Models/
  JournalEntry.swift   — @Model: photo (external storage), transcript, persona, language, placemark fields
  Trip.swift           — @Model: auto-grouped travel session (new country OR >5-day gap = new trip)
Lore/Services/
  LoreConfig.swift          — base URL, default + available models, token budget, useStreaming flag
  LoreSecrets.swift         — api-key + model + persona + language persistence (UserDefaults; Keychain TODO)
  LorePersona.swift         — Narrator / Professor / Skeptic; systemPrompt(contextLines:language:)
  LoreLanguage.swift        — 10 languages with native-name prompt lines + AVSpeechSynthesisVoice codes
  LoreMessage.swift         — Swift-side conversation turn (system/user/assistant; text or image+text)
  LoreService.swift         — OpenRouter client; streamLoreChat(messages:) SSE; offline-aware errors
  LoreSpeaker.swift         — AVSpeechSynthesizer + AVAudioSession (A2DP); streaming sentence split (Latin + CJK/Arabic terminators); per-language voice
  LoreLocationProvider.swift — CLLocationManager + CLGeocoder wrapper; throttled; contextLines formatter
  FrameSharpness.swift      — Laplacian-variance scoring for the recent-frames ring buffer
  JournalStore.swift        — @MainActor wrapper over ModelContext: save, resolveTrip, memoryContextLines
Lore/Views/
  LoreSettingsView.swift    — Form (api-key SecureField + model/persona/language Pickers)
  LoreOverlayView.swift     — HUD bubbles driven by LoreFlowState; "Tell me more" button; wifi.slash on offline
  JournalView.swift         — Timeline / Map / Search tabs + JournalEntryDetailView with Replay + Share
  LoreShareCard.swift       — 1080pt shareable card, ImageRenderer, UIActivityViewController bridge
```

`StreamSessionViewModel.runLorePipeline(with:)` is the single pipeline entry point. It's called from `capturePhoto()` (against the sharpest recent frame) and from `handlePhotoData()` (only if the frame-buffer path didn't already fire). It cancels any prior run, composes the layered system prompt, runs `streamLoreChat` or `loreChat` depending on `LoreConfig.useStreaming`, appends assistant responses to `conversationHistory`, and persists the first turn via `JournalStore.save`.

### Trip auto-grouping heuristic

Lives in `JournalStore.resolveTrip(for: placemark, now:)`. Ordered rules:
1. No active trip → new trip.
2. Active trip has an ISO country code AND incoming entry has a different one → new trip (border crossing is always a new trip).
3. `now - active.lastEntryAt >= 5 days` → new trip (vacation ended).
4. Otherwise → append to active. Backfills country on an active trip if the first entry was un-located and the second one is located.

Trip title is generated at creation time from placemark + month ("Barcelona, Spain · Apr 2026") and does not auto-rewrite on subsequent entries.

## How to work on this codebase

### Use the installed skills

This project has Meta-authored Claude Code skills in `.claude/skills/`. **Use them.** When the task touches:

| Topic | Skill |
|---|---|
| SDK setup, SPM, Info.plist, first connection | `.claude/skills/getting-started.md` |
| `StreamSession`, frames, photo capture, resolution/FPS | `.claude/skills/camera-streaming.md` |
| Pause/resume, state transitions, availability | `.claude/skills/session-lifecycle.md` |
| App registration with Meta AI, camera permissions | `.claude/skills/permissions-registration.md` |
| Testing without hardware | `.claude/skills/mockdevice-testing.md` |
| App architecture reference (ViewModels/Views structure) | `.claude/skills/sample-app-guide.md` |
| Common issues, Developer Mode, state diagnosis | `.claude/skills/debugging.md` |

Before writing any DAT-related Swift, consult the relevant skill. Invoke them via the `Skill` tool rather than re-reading from scratch each time.

### Also consult

- `.claude/rules/dat-conventions.md` — naming patterns (`Wearables.shared`, `*Session`, `*Selector`, `*Publisher`), async/await usage, `@MainActor` rules, imports
- `AGENTS.md` at the project root — full SDK reference for AI tools (also read by Cursor/Copilot)
- `/build` slash command — build via SPM

### Authoritative external docs

- Developer Center: https://wearables.developer.meta.com/docs/develop/
- iOS API reference: https://wearables.developer.meta.com/docs/reference/ios_swift/dat/0.6
- Machine-readable API dump: https://wearables.developer.meta.com/llms.txt?full=true
- GitHub (SDK source + samples): https://github.com/facebook/meta-wearables-dat-ios
- Discussions (for things Meta hasn't documented): https://github.com/facebook/meta-wearables-dat-ios/discussions

## Conventions specific to Lore

- **Swift style:** follow the conventions in `.claude/rules/dat-conventions.md` — async/await everywhere, `@MainActor` on UI-touching code, `.listen {}` for publishers, never block the main thread with frame processing.
- **Error handling:** do/catch on throwing SDK calls; surface user-facing errors via the existing `showError` / `loreState = .error(...)` patterns. For network failures, prefer `LoreServiceError.isOffline` detection so the overlay can show the `wifi.slash` state.
- **Secrets:** the OpenRouter API key must **never** be committed. It's entered by the user in the Settings sheet and persisted in UserDefaults via `LoreSecrets`. Never add scattered string literals for keys.
- **Prompt composition:** all prompt context threading happens in one place (`runLorePipeline(with:)`) via `LorePersona.systemPrompt(contextLines:language:)`. When adding a new context source (e.g., weather, time-of-day), feed it through that same call — do NOT build a parallel path.
- **Journal writes:** persistence happens in `finalizeAssistantTurn(text:)` gated on `followUpCount == 0`. Follow-ups share an entry with the initial turn. If a new feature needs its own entry, give it a distinct save call rather than reusing the initial-turn save.
- **No premature abstraction:** this is a portfolio MVP. Don't build a plugin system for "future lore sources" or similar. Ship the single happy path, then iterate.
- **Mock-first dev loop:** any new feature should work against `MWDATMockDevice` before requiring real hardware.

## Open questions / known gaps

1. **"Hey Meta" voice trigger** — not in public SDK. If Meta ships intent registration later, swap out the in-app button for voice. Track via Meta's discussions forum.
2. **Keychain migration** — `LoreSecrets` currently writes to `UserDefaults`. Move to Keychain before shipping outside of a portfolio context.
3. **Offline-first landmark database** — offline mode currently points at the Journal. A bundled SQLite of common landmarks + pre-computed facts would let new lore still happen in a tunnel or on a plane. Deferred to avoid shipping a large DB for V1.
4. **Follow-up journaling** — follow-ups are in-memory only; tapping "Tell me more" three times and then dismissing loses that content. If users want to keep follow-ups, store them on the `JournalEntry` as a `followUpTurns: [String]` array.
5. **TTS voices for niche languages** — iOS 17+ ships base voices for the 10 listed languages, but region-specific variants (e.g., `es-MX`) may not be installed. `LoreLanguage.speechVoice` falls back to the base language code, so this usually works, but it's worth flagging if a user picks Mandarin and hears a weird fallback.

## How to verify the app works

1. **Settings first** — launch app → tap the gear icon on the `NonStreamView` → "Lore settings" → paste an OpenRouter API key → pick a model + persona + language → Save. Nothing calls the API without this.
2. **MockDeviceKit (debug build)**: open debug menu → pair Ray-Ban Meta mock → start stream → tap Capture → verify the mock JPEG round-trips through OpenRouter (streaming) and TTS plays through the device speaker in the selected language. Verify the capture lands in Settings → Journal.
3. **Real hardware**: enable Developer Mode in Meta AI app → run on physical iPhone 16 Pro Max → pair real Ray-Ban Meta → start stream → tap Capture → verify TTS plays through the glasses speakers (A2DP). Verify Trip auto-grouping by capturing multiple moments and checking the Journal timeline headers.
4. **Offline path**: airplane mode → tap Capture → verify the overlay shows the `wifi.slash` icon + "Offline" header with the "Your Journal still works offline" copy.
5. **Follow-ups**: capture → wait for finish → tap "Tell me more" → verify a second stream fires against the same image, stays in persona voice, and the button disappears after 3 taps.

Always test the capture → OpenRouter → TTS → Journal save path end-to-end before claiming a feature works. Type-checking isn't enough for media-pipeline work.
