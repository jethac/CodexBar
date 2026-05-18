import CodexBarCore
import Foundation

extension SettingsStore {
    var geminiAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .gemini)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .gemini) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .gemini, field: "apiKey", value: newValue)
        }
    }
}
