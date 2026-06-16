import Foundation

public enum GoogleCloudProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .googlecloud,
            metadata: ProviderMetadata(
                id: .googlecloud,
                displayName: "Google Cloud",
                sessionLabel: "Spend",
                weeklyLabel: "Services",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Google Cloud usage",
                cliName: "googlecloud",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://console.cloud.google.com/billing",
                statusPageURL: nil,
                statusLinkURL: "https://status.cloud.google.com"),
            branding: ProviderBranding(
                iconStyle: .googlecloud,
                iconResourceName: "ProviderIcon-googlecloud",
                color: ProviderColor(red: 0.26, green: 0.52, blue: 0.96)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Google Cloud costs are reported by Cloud Billing export." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [GoogleCloudUsageFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "googlecloud",
                aliases: ["gcp", "google-cloud"],
                versionDetector: nil))
    }
}

struct GoogleCloudUsageFetchStrategy: ProviderFetchStrategy {
    let id = "googlecloud.api.billing"
    let kind: ProviderFetchKind = .apiToken
    let usageFetcher: @Sendable (GoogleCloudSettings, GoogleCloudServiceAccount) async throws -> GoogleCloudUsageSnapshot

    init(
        usageFetcher: @escaping @Sendable (GoogleCloudSettings, GoogleCloudServiceAccount) async throws
            -> GoogleCloudUsageSnapshot = { settings, account in
                try await GoogleCloudUsageFetcher.fetchUsage(settings: settings, serviceAccount: account)
            })
    {
        self.usageFetcher = usageFetcher
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        GoogleCloudSettingsReader.hasRequiredSettings(environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let settings = try GoogleCloudSettingsReader.settings(environment: context.env)
        let account = try GoogleCloudServiceAccount.load(path: settings.serviceAccountJSONPath)
        let usage = try await self.usageFetcher(settings, account)
        return self.makeResult(
            usage: usage.toUsageSnapshot(budget: settings.monthlyBudget),
            sourceLabel: usage.monitoringStatus == .available ? "bigquery-billing+monitoring" : "bigquery-billing")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
