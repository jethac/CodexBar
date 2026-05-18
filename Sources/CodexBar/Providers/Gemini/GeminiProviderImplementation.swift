import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct GeminiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .gemini
    let supportsLoginFlow: Bool = true

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.geminiAPIKey
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "gemini-api-key",
                title: "Gemini API key",
                subtitle: "Stored in ~/.codexbar/config.json. Used with Google OAuth to resolve AI Studio usage.",
                kind: .secure,
                placeholder: "AIza...",
                binding: context.stringBinding(\.geminiAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "gemini-open-api-keys",
                        title: "Open AI Studio API keys",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://aistudio.google.com/app/apikey") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runGeminiLoginFlow()
        return false
    }
}
