import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum GeminiProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .gemini,
            metadata: ProviderMetadata(
                id: .gemini,
                displayName: "Gemini",
                sessionLabel: "Pro",
                weeklyLabel: "Flash",
                opusLabel: "Flash Lite",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Gemini usage",
                cliName: "gemini",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://gemini.google.com",
                changelogURL: "https://github.com/google-gemini/gemini-cli/releases",
                statusPageURL: nil,
                statusLinkURL: "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history",
                statusWorkspaceProductID: "npdyhgECDJ6tB66MxXyo"),
            branding: ProviderBranding(
                iconStyle: .gemini,
                iconResourceName: "ProviderIcon-gemini",
                color: ProviderColor(red: 171 / 255, green: 135 / 255, blue: 234 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No Gemini CLI session token data found in ~/.gemini/tmp/*/chats." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [GeminiAPIKeyAIStudioFetchStrategy(), GeminiStatusFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "gemini",
                versionDetector: { _ in ProviderVersionDetector.geminiVersion() }))
    }
}

struct GeminiAPIKeyAIStudioFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "api-key-aistudio"

    let id: String = "gemini.api-key.aistudio"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        GeminiStatusProbe.currentAuthType(environment: context.env) == .apiKey
            && GeminiStatusProbe.currentAPIKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = GeminiStatusProbe.currentAPIKey(environment: context.env) else {
            throw GeminiStatusProbeError.unsupportedAuthType("API key")
        }

        let aiStudioContext = try await GeminiAIStudioBillingFetcher().resolveContext(apiKey: apiKey)
        let billingStatus = aiStudioContext.billingEnabled ? "billing enabled" : "free / billing disabled"
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .gemini,
                accountEmail: nil,
                accountOrganization: aiStudioContext.billingAccountID,
                loginMethod: "API key · \(billingStatus)"))
        return self.makeResult(usage: usage, sourceLabel: Self.sourceLabel)
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        GeminiStatusProbe.currentAuthType(environment: context.env) != .apiKey
    }
}

struct GeminiStatusFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "oauth-api"

    let id: String = "gemini.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = GeminiStatusProbe()
        let snap = try await probe.fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: Self.sourceLabel)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
