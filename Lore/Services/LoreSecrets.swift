import Foundation

// TODO: migrate to Keychain before any public release.
enum LoreSecrets {
  private static let apiKeyDefaultsKey = "lore.openRouterAPIKey"
  private static let modelDefaultsKey = "lore.openRouterModel"

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

  static var isConfigured: Bool { apiKey != nil }
}
