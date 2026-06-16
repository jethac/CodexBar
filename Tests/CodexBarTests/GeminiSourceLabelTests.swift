import Testing
@testable import CodexBarCore

struct GeminiSourceLabelTests {
    @Test
    func `Gemini API key strategy scrapes AI Studio usage without Gemini CLI OAuth`() async throws {
        let strategy = GeminiAPIKeyAIStudioFetchStrategy(scrapeResolver: { apiKey in
            #expect(apiKey == "saved-config-key")
            return GeminiAIStudioScrapeSnapshot(
                billing: GeminiAIStudioBillingSnapshot(plan: .prepay, availableCredits: 42.17),
                usage: GeminiAIStudioUsageSnapshot(requestCount: 1234, inputTokenCount: 5678, outputTokenCount: 9012))
        })
        let context = Self.makeContext(env: ["GEMINI_API_KEY": "saved-config-key"])

        let result = try await strategy.fetch(context)

        #expect(result.sourceLabel == GeminiAPIKeyAIStudioFetchStrategy.sourceLabel)
        #expect(result.usage.identity?.accountEmail == nil)
        #expect(result.usage.identity?.accountOrganization == "Prepay · $42.17 credits")
        #expect(result.usage.identity?.loginMethod == "API key · AI Studio")
        #expect(result.usage.providerCost?.used == 1234)
        #expect(result.usage.providerCost?.currencyCode == "Requests")
    }

    @Test
    func `Gemini API key strategy does not fall back to CLI when AI Studio scrape fails`() {
        let strategy = GeminiAPIKeyAIStudioFetchStrategy(scrapeResolver: { _ in
            throw GeminiAIStudioBillingError.missingAccessToken
        })
        let context = Self.makeContext(env: ["GEMINI_API_KEY": "saved-config-key"])

        #expect(strategy.shouldFallback(on: GeminiAIStudioBillingError.missingAccessToken, context: context) == false)
    }

    @Test
    func `Gemini CLI OAuth strategy remains available as optional fallback`() {
        #expect(GeminiStatusFetchStrategy.sourceLabel == "oauth-api")
    }

    @Test
    func `Gemini integration version is detached from installed CLI version`() {
        #expect(GeminiProviderDescriptor.integrationVersion == "0.44.0")
    }

    private static func makeContext(env: [String: String]) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
