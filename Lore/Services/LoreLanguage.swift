import AVFoundation
import Foundation

/// Output language for the lore response AND the TTS voice. Picked by the
/// user in Settings and persisted via `LoreSecrets.language`.
///
/// Two separate jobs:
/// 1. Steer the model to respond in this language via a system-prompt line.
/// 2. Select the right `AVSpeechSynthesisVoice` so TTS speaks it naturally
///    rather than mangling non-English text with an en-US voice.
///
/// The curated list is intentionally short. Anyone's first demo of this
/// app is going to be in one of these 10 — we can grow the list when
/// someone actually asks.
enum LoreLanguage: String, CaseIterable, Identifiable, Codable {
  case english
  case spanish
  case french
  case german
  case italian
  case portuguese
  case japanese
  case mandarin
  case hindi
  case arabic

  var id: String { rawValue }

  /// Human-readable name. English name so the Picker is scannable for
  /// non-native speakers of the UI language.
  var displayName: String {
    switch self {
    case .english: return "English"
    case .spanish: return "Spanish (Español)"
    case .french: return "French (Français)"
    case .german: return "German (Deutsch)"
    case .italian: return "Italian (Italiano)"
    case .portuguese: return "Portuguese (Português)"
    case .japanese: return "Japanese (日本語)"
    case .mandarin: return "Mandarin (中文)"
    case .hindi: return "Hindi (हिन्दी)"
    case .arabic: return "Arabic (العربية)"
    }
  }

  /// BCP-47 locale used to pick an `AVSpeechSynthesisVoice`. Region
  /// suffixes matter: "es-ES" and "es-MX" sound different, and iOS
  /// doesn't always have both installed. We pick the most common variant
  /// and fall back via `AVSpeechSynthesisVoice(language:)` lookup, which
  /// returns a reasonable default for the base language if the specific
  /// region isn't available.
  var voiceCode: String {
    switch self {
    case .english: return "en-US"
    case .spanish: return "es-ES"
    case .french: return "fr-FR"
    case .german: return "de-DE"
    case .italian: return "it-IT"
    case .portuguese: return "pt-BR"
    case .japanese: return "ja-JP"
    case .mandarin: return "zh-CN"
    case .hindi: return "hi-IN"
    case .arabic: return "ar-SA"
    }
  }

  /// Native-speaker label for the instruction to the model. Using the
  /// native name ("Responde en español") tends to produce more fluent
  /// output than asking in English ("Respond in Spanish") — the model
  /// locks onto the language earlier.
  var nativeName: String {
    switch self {
    case .english: return "English"
    case .spanish: return "español"
    case .french: return "français"
    case .german: return "Deutsch"
    case .italian: return "italiano"
    case .portuguese: return "português"
    case .japanese: return "日本語"
    case .mandarin: return "中文"
    case .hindi: return "हिन्दी"
    case .arabic: return "العربية"
    }
  }

  /// Line appended to the persona's system prompt when the user picks a
  /// non-English language. English is the model's default training
  /// language — don't waste tokens telling it to respond in English.
  var promptInstruction: String? {
    guard self != .english else { return nil }
    return
      "Respond in \(nativeName). Use natural, conversational \(nativeName), not translation-ese. Keep the persona's tone, just in this language."
  }

  /// Best available TTS voice for this language, or nil if iOS has none
  /// installed. In practice iOS 17+ ships at least a base voice for every
  /// entry here, but we defend against the nil case anyway.
  var speechVoice: AVSpeechSynthesisVoice? {
    AVSpeechSynthesisVoice(language: voiceCode)
      ?? AVSpeechSynthesisVoice(language: String(voiceCode.prefix(2)))
  }
}
