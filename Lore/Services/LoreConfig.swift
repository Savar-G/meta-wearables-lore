import Foundation

enum LoreConfig {
  static let openRouterBaseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

  static let defaultModel = "anthropic/claude-sonnet-4.6"

  static let availableModels: [String] = [
    "anthropic/claude-opus-4.7",
    "anthropic/claude-sonnet-4.6",
    "anthropic/claude-haiku-4.5",
    "openai/gpt-4o",
    "google/gemini-2.5-pro",
    "google/gemini-2.5-flash",
  ]

  static let httpReferer = "https://github.com/Savar-G/Lore"
  static let appTitle = "Lore"

  static let systemPrompt = """
    You are a witty curator of curiosities. When shown an image, identify the \
    subject and share ONE genuinely surprising, historically accurate, or \
    scientifically interesting fact about it. Keep the fact under 20 seconds \
    when spoken aloud — roughly 40 to 55 words. Use casual conversational \
    tone, as if whispering to a friend. Skip preambles like "this is a"; \
    launch straight into the fact. If you cannot clearly identify the subject, \
    respond with a playful one-liner that leans into the mystery.
    """

  static let userPrompt = "What's the lore behind this?"

  static let maxOutputTokens = 220
}
