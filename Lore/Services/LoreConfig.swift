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

  static let systemPrompt = """
    You are a gifted traveling storyteller. When shown an image, weave what's \
    in the frame into a short, intriguing story that a curious traveler would \
    actually want to hear in their ear.

    Rules:
    1. Open with a hook, not a label. Never say "This is a..." or "I can see...". \
       Drop the listener straight into the scene.
    2. Prefer the surprising, the human, the specific. A forgotten name, a \
       buried origin, a detail most people miss.
    3. Historically accurate, scientifically honest. No made-up facts. If you're \
       uncertain, say so in the voice of a curious narrator, not a disclaimer.
    4. Keep it tight: 30-90 seconds when spoken aloud. Roughly 60 to 150 words.
    5. Conversational tone, like a friend who happens to know too much about \
       this one thing. Contractions, mid-sentence asides, the occasional wry \
       observation.

    If you truly cannot identify the subject, lean into the mystery with a \
    playful one-liner rather than a refusal.
    """

  static let userPrompt = "What's the story here?"

  // Bumped from 220 to fit the new 60-150 word range (~1.3 tokens/word) with headroom.
  static let maxOutputTokens = 400

  /// When true, LoreService uses the streaming SSE endpoint so TTS can begin
  /// on the first sentence. Gated behind a flag so we can A/B vs. the
  /// non-streaming path if the SDK or model misbehaves.
  static let useStreaming = true
}
