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
5. App sends the JPEG to the Claude Vision API with a prompt like *"Identify what's in this image and give me one genuinely interesting, surprising fun fact about it — keep it under 20 seconds when spoken aloud."*
6. Response text is spoken via `AVSpeechSynthesizer`, routed to the glasses speakers through `AVAudioSession` with `.allowBluetooth` (A2DP)

### Scope for MVP
- **Trigger:** in-app button only. The public Meta Wearables DAT SDK (v0.6.0 developer preview) does **not** expose custom voice-intent registration with "Hey Meta" — the hardware capture button routes to Meta's own app, not third-party apps. Treat voice-first UX as a future feature contingent on Meta exposing intents.
- **Audio output:** through glasses speakers via standard iOS `AVAudioSession` (confirmed, uses A2DP profile)
- **Dev loop:** use `MWDATMockDevice` with a test image before touching hardware

## Stack

- **iOS app:** SwiftUI, forked from Meta's `samples/CameraAccess/` reference app
- **SDK:** Meta Wearables Device Access Toolkit (DAT) v0.6.0 via Swift Package Manager
  - Modules: `MWDATCore` (required), `MWDATCamera` (required), `MWDATMockDevice` (debug-only)
- **AI:** Claude Vision API (`claude-opus-4-7` or `claude-sonnet-4-6`) for image → fun-fact
- **TTS:** `AVSpeechSynthesizer` (built into iOS) routed through glasses

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
- **Secrets:** the Claude API key must **never** be committed. Store via `.xcconfig` (gitignored) or the iOS Keychain — wire it up through a `LoreSecrets` abstraction, not scattered string literals
- **No premature abstraction:** this is a portfolio MVP. Don't build a plugin system for "future lore sources" or similar. Ship the single happy path, then iterate
- **Mock-first dev loop:** any new feature should work against `MWDATMockDevice` before requiring real hardware

## Open questions / known gaps

1. **"Hey Meta" voice trigger** — not in public SDK. If Meta ships intent registration later, swap out the in-app button for voice. Track via Meta's discussions forum.
2. **TTS latency** — end-to-end capture → Claude → TTS may feel slow. If > 3s, stream the Claude response and start TTS on the first sentence.
3. **Failure modes** — what happens when Claude returns "I can't identify this image"? Probably a generic curiosity line ("I don't know what that is, but whatever it is, it's yours now"). Design the fallbacks deliberately.

## How to verify the app works

1. MockDeviceKit (debug build): launch app → open debug menu → pair Ray-Ban Meta → start stream → tap Capture → verify mock photo flows through Claude Vision → TTS plays
2. Real hardware: enable Developer Mode in Meta AI app → run on physical iPhone → pair glasses → full end-to-end test

Always test the capture → Claude → TTS path end-to-end before claiming a feature works. Type-checking isn't enough for media-pipeline work.
