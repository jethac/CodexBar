import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct AiAndProviderTests {
    @Test
    func `summary maps to a 30-day USD spend snapshot without rate windows`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-fixture")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(url.absoluteString == "https://api.aiand.com/analytics/summary?range=30days")
            #expect(url.scheme == "https")
            #expect(url.host == "api.aiand.com")
            #expect(url.query == "range=30days")
            #expect(url.user == nil)
            #expect(url.password == nil)
            #expect(url.fragment == nil)
            return Self.response(url: url, body: Self.summaryFixture)
        }

        let usage = try await AiAndUsageFetcher.fetchUsage(
            "sk-test-fixture",
            transport: transport,
            now: now)
        let snapshot = usage.toUsageSnapshot()

        #expect(usage.last30DaysCostUSD == 42.18)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.extraRateWindows == nil)
        #expect(snapshot.providerCost?.used == 42.18)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.providerCost?.period == "Last 30 days")
        #expect(snapshot.identity == nil)
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func `credential is only sent as a bearer header`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: Self.summaryFixture)
        }

        _ = try await AiAndUsageFetcher.fetchUsage("sk-test-fixture", transport: transport)

        let request = try #require(await transport.requests().first)
        let url = try #require(request.url)
        #expect(!url.absoluteString.contains("sk-test-fixture"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-fixture")
    }

    @Test
    func `invalid api key maps to an actionable error`() async {
        let transport = Self.errorTransport(statusCode: 401, code: "invalid_api_key")

        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("sk-wrong", transport: transport)
        } throws: { error in
            error as? AiAndUsageError == .invalidAPIKey
        }
        #expect(AiAndUsageError.invalidAPIKey.errorDescription?.contains("console.aiand.com") == true)
    }

    @Test
    func `insufficient credits maps to an actionable error`() async {
        let transport = Self.errorTransport(statusCode: 402, code: "insufficient_credits")

        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("sk-test-fixture", transport: transport)
        } throws: { error in
            error as? AiAndUsageError == .insufficientCredits
        }
        #expect(AiAndUsageError.insufficientCredits.errorDescription?.contains("credits") == true)
    }

    @Test
    func `rate limit is surfaced politely`() async {
        let transport = Self.errorTransport(statusCode: 429, code: "rate_limit_exceeded")

        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("sk-test-fixture", transport: transport)
        } throws: { error in
            error as? AiAndUsageError == .rateLimited
        }
    }

    @Test
    func `unexpected status is reported with its code`() async {
        let transport = Self.errorTransport(statusCode: 500, code: "internal_error")

        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("sk-test-fixture", transport: transport)
        } throws: { error in
            error as? AiAndUsageError == .apiError(500)
        }
    }

    @Test
    func `missing or whitespace credential fails clearly`() async {
        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("   ")
        } throws: { error in
            error as? AiAndUsageError == .notConfigured
        }
    }

    @Test
    func `malformed summary payload fails parsing`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: #"{"range":"30days"}"#)
        }

        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("sk-test-fixture", transport: transport)
        } throws: { error in
            guard case .parseFailed = error as? AiAndUsageError else { return false }
            return true
        }
    }

    @Test
    func `settings reader trims whitespace and quotes`() {
        #expect(AiAndSettingsReader.apiKey(environment: [
            AiAndSettingsReader.apiKeyEnvironmentKey: "  'sk-test-fixture'  ",
        ]) == "sk-test-fixture")
        #expect(AiAndSettingsReader.apiKey(environment: [:]) == nil)
        #expect(AiAndSettingsReader.apiKey(environment: [
            AiAndSettingsReader.apiKeyEnvironmentKey: "   ",
        ]) == nil)
    }

    @Test @MainActor
    func `descriptor and app registry include aiand`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .aiand)
        #expect(descriptor.metadata.displayName == "ai&")
        #expect(descriptor.metadata.cliName == "aiand")
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(!descriptor.metadata.supportsCredits)
        #expect(!descriptor.tokenCost.supportsTokenCost)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.cli.aliases == ["ai&", "ai-and"])

        let implementation = try #require(ProviderImplementationRegistry.implementation(for: .aiand))
        #expect(implementation is AiAndProviderImplementation)
    }

    @Test @MainActor
    func `menu card renders spend through the generic API-spend path`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: Self.summaryFixture)
        }
        let usage = try await AiAndUsageFetcher.fetchUsage(
            "sk-test-fixture",
            transport: transport,
            now: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .aiand,
            metadata: AiAndProviderDescriptor.descriptor.metadata,
            snapshot: usage.toUsageSnapshot(),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.isEmpty)
        #expect(model.creditsText == nil)
        #expect(model.providerCost?.title == "API spend")
        #expect(model.providerCost?.spendLine == "Last 30 days: $42.18")
        #expect(model.providerCost?.percentUsed == nil)
        #expect(model.providerCost?.percentLine == nil)
    }

    /// Sanitized from the documented /analytics/summary example (docs.aiand.com/analytics/summary/).
    private static let summaryFixture = #"""
    {
      "range": "30days",
      "from": "2026-06-17T00:00:00Z",
      "to": "2026-07-17T00:00:00Z",
      "requests": 87432,
      "input_tokens": 12345678,
      "output_tokens": 234567,
      "cost_usd": 42.18,
      "errors": 312,
      "p50_latency_ms": 410,
      "p95_latency_ms": 1820
    }
    """#

    private static func errorTransport(statusCode: Int, code: String) -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let body = #"""
            {"error":{"message":"fixture error","type":"fixture","param":null,"code":"\#(code)"}}
            """#
            return Self.response(url: url, body: body, statusCode: statusCode)
        }
    }

    private static func response(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}
