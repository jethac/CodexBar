import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct GoogleCloudProviderTests {
    @Test
    func `settings reader resolves required values and defaults monitoring project`() throws {
        let settings = try GoogleCloudSettingsReader.settings(environment: [
            GoogleCloudSettingsReader.billingProjectIDKey: "billing-proj",
            GoogleCloudSettingsReader.billingDatasetIDKey: "billing_export",
            GoogleCloudSettingsReader.serviceAccountJSONPathKey: "~/sa.json",
            GoogleCloudSettingsReader.topRowCountKey: "50",
        ])

        #expect(settings.billingProjectID == "billing-proj")
        #expect(settings.billingDatasetID == "billing_export")
        #expect(settings.monitoringProjectID == "billing-proj")
        #expect(settings.serviceAccountJSONPath == "~/sa.json")
        #expect(settings.topRowCount == 25)
        #expect(settings.monitoringEnabled)
    }

    @Test
    func `provider config environment projects Google Cloud fields`() {
        let config = ProviderConfig(
            id: .googlecloud,
            extrasEnabled: false,
            apiKey: "~/sa.json",
            secretKey: "monitoring-proj",
            cookieHeader: "123.45",
            region: "billing_dataset",
            workspaceID: "billing-proj",
            enterpriseHost: "gcp_billing_export_v1_ABCDEF",
            awsProfile: "cost_center",
            awsAuthMode: "12")
        let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .googlecloud,
            config: config)

        #expect(env[GoogleCloudSettingsReader.billingProjectIDKey] == "billing-proj")
        #expect(env[GoogleCloudSettingsReader.billingDatasetIDKey] == "billing_dataset")
        #expect(env[GoogleCloudSettingsReader.billingTableIDKey] == "gcp_billing_export_v1_ABCDEF")
        #expect(env[GoogleCloudSettingsReader.serviceAccountJSONPathKey] == "~/sa.json")
        #expect(env[GoogleCloudSettingsReader.monitoringProjectIDKey] == "monitoring-proj")
        #expect(env[GoogleCloudSettingsReader.budgetKey] == "123.45")
        #expect(env[GoogleCloudSettingsReader.costLabelKey] == "cost_center")
        #expect(env[GoogleCloudSettingsReader.topRowCountKey] == "12")
        #expect(env[GoogleCloudSettingsReader.monitoringEnabledKey] == "false")
    }

    @Test
    func `monitoring aggregation groups credentials methods response codes and days`() throws {
        let data = Data("""
        {
          "timeSeries": [
            {
              "metric": { "labels": { "response_code": "200" } },
              "resource": { "labels": {
                "credential_id": "apikey:abcdef123456",
                "method": "google.ai.generativelanguage.v1.GenerateContent"
              } },
              "points": [
                { "interval": { "startTime": "2026-06-01T00:00:00Z" }, "value": { "int64Value": "3" } }
              ]
            },
            {
              "metric": { "labels": { "response_code": "429" } },
              "resource": { "labels": {
                "credential_id": "apikey:abcdef123456",
                "method": "google.ai.generativelanguage.v1.GenerateContent"
              } },
              "points": [
                { "interval": { "startTime": "2026-06-01T00:00:00Z" }, "value": { "int64Value": "2" } }
              ]
            }
          ]
        }
        """.utf8)
        let response = try JSONDecoder().decode(TimeSeriesResponse.self, from: data)
        let service = GoogleCloudMonitoringClient.aggregateGeminiService(response.timeSeries ?? [])

        #expect(service.requestCount == 5)
        #expect(service.successfulRequestCount == 3)
        #expect(service.errorRequestCount == 2)
        #expect(service.credentials.first?.credentialID == "abcdef123456")
        #expect(service.credentials.first?.displayID == "****3456")
        #expect(service.methods.first?.method == "GenerateContent")
        #expect(service.responseCodes.map(\.responseCode) == ["200", "429"])
        #expect(service.dailyRequests.first?.date == "2026-06-01")
        #expect(service.latestSampleDate == "2026-06-01")
    }

    @Test
    func `monitoring-only Gemini activity creates zero cost row`() {
        let service = GoogleCloudMonitoredService(
            id: GoogleCloudCostRow.geminiAPIID,
            title: "Gemini API",
            requestCount: 42,
            successfulRequestCount: 40,
            errorRequestCount: 2,
            credentials: [],
            methods: [],
            responseCodes: [],
            dailyRequests: [],
            latestSampleDate: "2026-06-16")

        let rows = GoogleCloudUsageFetcher.attachMonitoring(service, to: [])

        #expect(rows.count == 1)
        #expect(rows.first?.id == GoogleCloudCostRow.geminiAPIID)
        #expect(rows.first?.netCost == 0)
        #expect(rows.first?.requestCount == 42)
    }

    @Test
    func `usage snapshot encodes google cloud payload`() throws {
        let period = GoogleCloudBillingPeriod(startDate: "2026-06-01", endDate: "2026-07-01", label: "This month")
        let google = GoogleCloudUsageSnapshot(
            period: period,
            currencyCode: "USD",
            grossCost: 11,
            credits: -1,
            netCost: 10,
            rows: [
                GoogleCloudCostRow(
                    id: GoogleCloudCostRow.geminiAPIID,
                    title: "Gemini API",
                    kind: .special,
                    grossCost: 11,
                    credits: -1,
                    netCost: 10,
                    percentOfTotal: 100),
            ],
            monitoring: nil,
            monitoringStatus: .unavailable,
            warnings: ["Cloud Monitoring unavailable"],
            exportTable: "gcp_billing_export_v1_ABCDEF",
            exportKind: .standard,
            billingLatestUsageDate: "2026-06-15",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000))

        let snapshot = google.toUsageSnapshot(budget: nil)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)

        #expect(decoded.providerCost?.used == 10)
        #expect(decoded.providerCost?.limit == 0)
        #expect(decoded.googleCloudUsage?.rows.first?.title == "Gemini API")
        #expect(decoded.googleCloudUsage?.monitoringStatus == .unavailable)
        #expect(decoded.googleCloudUsage?.billingLatestUsageDate == "2026-06-15")
    }

    @Test
    func `bigquery rows decode field wrappers`() throws {
        let data = Data(#"{ "f": [ { "v": "USD" }, { "v": "12.5" }, { "v": "-2.5" } ] }"#.utf8)
        let row = try JSONDecoder().decode(BigQueryRow.self, from: data)

        #expect(row.string(0) == "USD")
        #expect(row.double(1) == 12.5)
        #expect(row.double(2) == -2.5)
    }

    @Test
    func `doctor reports missing settings and skips dependent checks`() async {
        let report = await GoogleCloudDoctor.run(environment: [:])

        #expect(report.status == .failure)
        #expect(report.steps.first?.id == "settings")
        #expect(report.steps.first?.status == .failure)
        #expect(report.steps.dropFirst().allSatisfy { $0.status == .skipped })
    }

    @Test
    func `missing settings surface concrete fetch error instead of unavailable strategy`() async throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .googlecloud)
        let outcome = await descriptor.fetchOutcome(context: Self.makeFetchContext(environment: [:]))

        #expect(outcome.attempts.map(\.strategyID) == ["googlecloud.api.billing"])
        #expect(outcome.attempts.first?.wasAvailable == true)

        do {
            _ = try outcome.result.get()
            Issue.record("Expected Google Cloud fetch to fail without settings")
        } catch let error as GoogleCloudUsageError {
            #expect(error == .missingSetting("billing project id"))
        } catch {
            Issue.record("Expected GoogleCloudUsageError, got \(error)")
        }
    }

    private static func makeFetchContext(environment: [String: String]) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: GoogleCloudStubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}

private struct GoogleCloudStubClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw GoogleCloudUsageError.missingCredentials
    }

    func debugRawProbe(model _: String) async -> String {
        "stub"
    }

    func detectVersion() -> String? {
        nil
    }
}
