import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum GeminiProviderDescriptor {
    public static let integrationVersion = "0.44.0"

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
                versionDetector: { _ in self.integrationVersion }))
    }
}

struct GeminiAPIKeyAIStudioFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "api-key-aistudio"
    typealias ScrapeResolver = @Sendable (String) async throws -> GeminiAIStudioScrapeSnapshot

    let id: String = "gemini.api-key.aistudio"
    let kind: ProviderFetchKind = .apiToken
    private let scrapeResolver: ScrapeResolver

    init(scrapeResolver: @escaping ScrapeResolver = { apiKey in
        try await GeminiAIStudioScrapeFetcher().scrape(apiKey: apiKey)
    }) {
        self.scrapeResolver = scrapeResolver
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        GeminiStatusProbe.currentAPIKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = GeminiStatusProbe.currentAPIKey(environment: context.env) else {
            throw GeminiStatusProbeError.unsupportedAuthType("API key")
        }
        let scrape = try await self.scrapeResolver(apiKey)

        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: Self.providerCost(from: scrape.usage),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .gemini,
                accountEmail: nil,
                accountOrganization: Self.billingSummary(from: scrape.billing),
                loginMethod: "API key · AI Studio"))
        return self.makeResult(usage: usage, sourceLabel: Self.sourceLabel)
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        GeminiStatusProbe.currentAPIKey(environment: context.env) == nil
    }

    private static func billingSummary(from billing: GeminiAIStudioBillingSnapshot) -> String? {
        let plan = billing.plan.rawValue.capitalized
        if let availableCredits = billing.availableCredits {
            return "\(plan) · $\(Self.amountString(availableCredits)) credits"
        }
        if let spend = billing.monthToDateSpend, let cap = billing.spendCap {
            return "\(plan) · $\(Self.amountString(spend)) / $\(Self.amountString(cap))"
        }
        if billing.plan != .unknown { return plan }
        return nil
    }

    private static func providerCost(from usage: GeminiAIStudioUsageSnapshot) -> ProviderCostSnapshot? {
        guard let requestCount = usage.requestCount else { return nil }
        return ProviderCostSnapshot(
            used: Double(requestCount),
            limit: max(Double(requestCount), 1),
            currencyCode: "Requests",
            period: "Today",
            resetsAt: nil,
            updatedAt: Date())
    }

    private static func amountString(_ value: Double) -> String {
        String(format: "%.2f", value)
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
