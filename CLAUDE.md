# Lore — Project Instructions for Claude

## Project context

**Lore** is a portfolio iOS companion app for Meta Ray-Ban smart glasses. Product framing: *"Life's too boring — make the mundane feel alive."*

The user taps a button in the iOS app, the glasses capture whatever they're looking at, and the app speaks back a short, surprising fun-fact ("lore") about that thing through the glasses speakers. It's not about information retrieval — it's about curiosity as a feature.

### One-line concept
> Point at anything. Learn something cool.

### Core flow
1. User opens Lore on iPhone, registers with Meta AI, pairs with glasses
2. User taps **Capture** button in the app
3. App calls `StreamSession.capturePhoto(format: .jpeg)` on the paired glasses
4. Photo bytes arrive via `photoDataPublisher`
5. App sends the JPEG to **OpenRouter** (`/api/v1/chat/completions`, OpenAI-compatible schema) with a vision-capable model. Default: `anthropic/claude-sonnet-4.6`. Prompt: *"Identify what's in this image and give me one genuinely interesting, surprising fun fact about it — keep it under 20 seconds when spoken aloud."* The model is user-selectable in the in-app Settings sheet.
6. Response text is spoken via `AVSpeechSynthesizer`, routed to the glasses speakers through `AVAudioSession` with `.allowBluetooth` (A2DP)

### Scope for MVP
- **Trigger:** in-app button only. The public Meta Wearables DAT SDK (v0.6.0 developer preview) does **not** expose custom voice-intent registration with "Hey Meta" — the hardware capture button routes to Meta's own app, not third-party apps. Treat voice-first UX as a future feature contingent on Meta exposing intents.
- **Audio output:** through glasses speakers via standard iOS `AVAudioSession` (confirmed, uses A2DP profile)
- **Dev loop:** use `MWDATMockDevice` with a test image before touching hardware

## Stack

- **iOS app:** SwiftUI, forked from Meta's `samples/CameraAccess/` reference app
- **SDK:** Meta Wearables Device Access Toolkit (DAT) v0.6.0 via Swift Package Manager
  - Modules: `MWDATCore` (required), `MWDATCamera` (required), `MWDATMockDevice` (debug-only)
- **AI:** OpenRouter (any vision-capable model). Default `anthropic/claude-sonnet-4.6`. Other options in `LoreConfig.availableModels` (Opus 4.7, Haiku 4.5, GPT-4o, Gemini 2.5 Pro/Flash). The user's API key + model selection live in the in-app Settings sheet (`LoreSettingsView`), persisted via `LoreSecrets` (UserDefaults for MVP; Keychain TODO)
- **TTS:** `AVSpeechSynthesizer` (built into iOS) routed through glasses

### Lore pipeline code layout

```
Lore/Services/
  LoreConfig.swift   — base URL, default + available models, system prompt, token budget
  LoreSecrets.swift  — api-key + model persistence (UserDefaults, Keychain TODO)
  LoreService.swift  — OpenRouter client: lore(forJPEG: Data) async throws -> String
  LoreSpeaker.swift  — AVSpeechSynthesizer wrapper, configures AVAudioSession for A2DP
Lore/Views/
  LoreSettingsView.swift  — SwiftUI Form (api-key SecureField + model Picker)
  LoreOverlayView.swift   — HUD bubbles driven by LoreFlowState enum
```

`StreamSessionViewModel.runLorePipeline(with:)` is the single pipeline entry point. It's called from `handlePhotoData` after `photoDataPublisher` fires. It cancels any prior run, sets `loreState = .thinking`, calls `LoreService`, then `.speaking`, then delegates to `LoreSpeaker`; the speaker's completion flips state to `.finished`.

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

- **Swift style:** follow the conventions in `.claude/rules/dat-conventions.md` — async/await everywhere, `@MainActor` on UI-touching code, `.listen {}` for publishers, never block the main thread with frame processing
- **Error handling:** do/catch on throwing SDK calls, surface user-facing errors via the existing `WearablesViewModel.showError` pattern (inherited from CameraAccess)
- **Secrets:** the OpenRouter API key must **never** be committed. It's entered by the user in the Settings sheet and persisted in UserDefaults via `LoreSecrets` (Keychain migration is an open TODO). Never add scattered string literals for keys.
- **No premature abstraction:** this is a portfolio MVP. Don't build a plugin system for "future lore sources" or similar. Ship the single happy path, then iterate
- **Mock-first dev loop:** any new feature should work against `MWDATMockDevice` before requiring real hardware

## Open questions / known gaps

1. **"Hey Meta" voice trigger** — not in public SDK. If Meta ships intent registration later, swap out the in-app button for voice. Track via Meta's discussions forum.
2. **TTS latency** — end-to-end capture → OpenRouter → TTS may feel slow. If > 3s, switch to a streaming chat completion and start TTS on the first sentence.
3. **Failure modes** — when the model returns "I can't identify this image", the system prompt asks it to respond with a playful one-liner. Real-world behavior needs to be validated on hardware.
4. **Keychain migration** — `LoreSecrets` currently writes to `UserDefaults`. Move to Keychain before shipping outside of a portfolio context.

## How to verify the app works

1. **Settings first** — launch app → tap the gear icon on the `NonStreamView` → "Lore settings" → paste an OpenRouter API key → pick a model → Save. Nothing calls the API without this.
2. **MockDeviceKit (debug build)**: open debug menu → pair Ray-Ban Meta mock → start stream → tap Capture → verify the mock JPEG round-trips through OpenRouter and TTS plays through the device speaker.
3. **Real hardware**: enable Developer Mode in Meta AI app → run on physical iPhone 16 Pro Max → pair real Ray-Ban Meta → start stream → tap Capture → verify TTS plays through the glasses speakers (A2DP).

Always test the capture → OpenRouter → TTS path end-to-end before claiming a feature works. Type-checking isn't enough for media-pipeline work.
