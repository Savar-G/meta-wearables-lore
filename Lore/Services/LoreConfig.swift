import Foundation

enum LoreConfig {
  static let openRouterBaseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

  static let defaultModel = "qwen/qwen3.6-plus"

  static let availableModels: [String] = [
    "anthropic/claude-opus-4.7",
    "anthropic/claude-sonnet-4.6",
    "anthropic/claude-haiku-4.5",
    "openai/gpt-4o",
    "qwen/qwen3.6-plus",
    "google/gemini-2.5-pro",
    "google/gemini-2.5-flash",
  ]

  static let httpReferer = "https://github.com/Savar-G/meta-wearables-lore"
  static let appTitle = "Lore"

  // The system prompt now lives per-persona on `LorePersona`. The ViewModel
  // composes the per-request prompt by calling
  // `LoreSecrets.persona.systemPrompt(contextLines:)` and hands it to
  // `LoreService`. Keeping it out of LoreConfig avoids a second source of
  // truth drifting from the Settings picker.

  static let userPrompt = "What's the story here?"

  // Bumped from 220 to fit the new 60-150 word range (~1.3 tokens/word) with headroom.
  static let maxOutputTokens = 400

  /// When true, LoreService uses the streaming SSE endpoint so TTS can begin
  /// on the first sentence. Gated behind a flag so we can A/B vs. the
  /// non-streaming path if the SDK or model misbehaves.
  static let useStreaming = true
}
