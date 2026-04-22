import Foundation

// TODO: migrate to Keychain before any public release.
enum LoreSecrets {
  private static let apiKeyDefaultsKey = "lore.openRouterAPIKey"
  private static let modelDefaultsKey = "lore.openRouterModel"
  private static let personaDefaultsKey = "lore.persona"
  private static let languageDefaultsKey = "lore.language"

  static var apiKey: String? {
    get {
      let value = UserDefaults.standard.string(forKey: apiKeyDefaultsKey)
      return (value?.isEmpty ?? true) ? nil : value
    }
    set {
      if let value = newValue, !value.isEmpty {
        UserDefaults.standard.set(value, forKey: apiKeyDefaultsKey)
      } else {
        UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
      }
    }
  }

  static var model: String {
    get { UserDefaults.standard.string(forKey: modelDefaultsKey) ?? LoreConfig.defaultModel }
    set { UserDefaults.standard.set(newValue, forKey: modelDefaultsKey) }
  }

  /// Currently selected narrator voice. Defaults to `.narrator` when the user
  /// has never picked one — matches the pre-persona copy.
  static var persona: LorePersona {
    get {
      guard
        let raw = UserDefaults.standard.string(forKey: personaDefaultsKey),
        let value = LorePersona(rawValue: raw)
      else {
        return .narrator
      }
      return value
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: personaDefaultsKey)
    }
  }

  /// Output language for lore responses and TTS. Defaults to English.
  /// Changing this mid-session affects the NEXT capture; the current lore
  /// finishes in whatever language it started.
  static var language: LoreLanguage {
    get {
      guard
        let raw = UserDefaults.standard.string(forKey: languageDefaultsKey),
        let value = LoreLanguage(rawValue: raw)
      else {
        return .english
      }
      return value
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: languageDefaultsKey)
    }
  }

  static var isConfigured: Bool { apiKey != nil }
}
