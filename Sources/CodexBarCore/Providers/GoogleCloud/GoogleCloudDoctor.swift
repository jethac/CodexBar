import Foundation

public enum GoogleCloudDoctorStatus: String, Codable, Sendable, Comparable {
    case success
    case warning
    case failure
    case skipped

    public static func < (lhs: GoogleCloudDoctorStatus, rhs: GoogleCloudDoctorStatus) -> Bool {
        Self.rank(lhs) < Self.rank(rhs)
    }

    private static func rank(_ status: GoogleCloudDoctorStatus) -> Int {
        switch status {
        case .success: 0
        case .skipped: 1
        case .warning: 2
        case .failure: 3
        }
    }
}

public struct GoogleCloudDoctorStep: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let status: GoogleCloudDoctorStatus
    public let message: String
    public let detail: String?

    public init(
        id: String,
        title: String,
        status: GoogleCloudDoctorStatus,
        message: String,
        detail: String? = nil)
    {
        self.id = id
        self.title = title
        self.status = status
        self.message = message
        self.detail = detail
    }
}

public struct GoogleCloudDoctorReport: Codable, Sendable, Equatable {
    public let provider: UsageProvider
    public let checkedAt: Date
    public let steps: [GoogleCloudDoctorStep]

    public init(checkedAt: Date, steps: [GoogleCloudDoctorStep]) {
        self.provider = .googlecloud
        self.checkedAt = checkedAt
        self.steps = steps
    }

    public var status: GoogleCloudDoctorStatus {
        self.steps.map(\.status).max() ?? .skipped
    }
}

public enum GoogleCloudDoctor {
    public static func run(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async -> GoogleCloudDoctorReport
    {
        var steps: [GoogleCloudDoctorStep] = []

        let settings: GoogleCloudSettings
        do {
            settings = try GoogleCloudSettingsReader.settings(environment: environment)
            steps.append(.success(
                id: "settings",
                title: "Settings",
                message: "Billing project and dataset are configured.",
                detail: "billingProject=\(settings.billingProjectID), dataset=\(settings.billingDatasetID)"))
        } catch {
            steps.append(.failure(
                id: "settings",
                title: "Settings",
                message: Self.message(error)))
            steps.append(.skipped(id: "credentials", title: "Credentials", message: "Settings must be fixed first."))
            steps.append(.skipped(id: "oauth", title: "OAuth", message: "Credentials were not loaded."))
            steps.append(.skipped(id: "bigquery", title: "BigQuery billing export", message: "OAuth was not verified."))
            steps.append(.skipped(id: "monitoring", title: "Cloud Monitoring", message: "OAuth was not verified."))
            return GoogleCloudDoctorReport(checkedAt: now, steps: steps)
        }

        let account: GoogleCloudServiceAccount
        do {
            account = try GoogleCloudServiceAccount.load(path: settings.serviceAccountJSONPath)
            _ = try GoogleCloudServiceAccountTokenProvider.jwtAssertion(
                account: account,
                scopes: [GoogleCloudBigQueryClient.readonlyScope],
                issuedAt: now,
                expiresAt: now.addingTimeInterval(300))
            steps.append(.success(
                id: "credentials",
                title: "Credentials",
                message: "Service account JSON loaded and the private key can sign JWTs.",
                detail: "account=\(Self.redactedEmail(account.clientEmail))"))
        } catch {
            steps.append(.failure(
                id: "credentials",
                title: "Credentials",
                message: Self.message(error)))
            steps.append(.skipped(id: "oauth", title: "OAuth", message: "Credentials were not loaded."))
            steps.append(.skipped(id: "bigquery", title: "BigQuery billing export", message: "OAuth was not verified."))
            steps.append(.skipped(id: "monitoring", title: "Cloud Monitoring", message: "OAuth was not verified."))
            return GoogleCloudDoctorReport(checkedAt: now, steps: steps)
        }

        let tokenProvider = GoogleCloudServiceAccountTokenProvider(
            account: account,
            transport: transport,
            now: { now })
        do {
            _ = try await tokenProvider.accessToken(scopes: [
                GoogleCloudBigQueryClient.readonlyScope,
                GoogleCloudMonitoringClient.readonlyScope,
            ])
            steps.append(.success(
                id: "oauth",
                title: "OAuth",
                message: "Token exchange succeeded for BigQuery and Monitoring scopes."))
        } catch {
            steps.append(.failure(
                id: "oauth",
                title: "OAuth",
                message: Self.message(error)))
            steps.append(.skipped(id: "bigquery", title: "BigQuery billing export", message: "OAuth failed."))
            steps.append(.skipped(id: "monitoring", title: "Cloud Monitoring", message: "OAuth failed."))
            return GoogleCloudDoctorReport(checkedAt: now, steps: steps)
        }

        let period = GoogleCloudUsageFetcher.currentMonthPeriod(now: now)
        let billingClient = GoogleCloudBigQueryClient(tokenProvider: tokenProvider, transport: transport)
        do {
            let billing = try await billingClient.fetchBilling(settings: settings, period: period)
            let freshness = billing.latestUsageDate.map { "latestUsage=\($0)" } ?? "latestUsage=none"
            steps.append(.success(
                id: "bigquery",
                title: "BigQuery billing export",
                message: "Billing export table is queryable.",
                detail: "\(billing.exportTable.tableID), \(freshness), net=\(billing.netCost) \(billing.currencyCode)"))
        } catch {
            steps.append(.failure(
                id: "bigquery",
                title: "BigQuery billing export",
                message: Self.message(error),
                detail: Self.bigQueryHint(error)))
        }

        guard settings.monitoringEnabled else {
            steps.append(.skipped(
                id: "monitoring",
                title: "Cloud Monitoring",
                message: "Monitoring is disabled for this provider."))
            return GoogleCloudDoctorReport(checkedAt: now, steps: steps)
        }

        let monitoringClient = GoogleCloudMonitoringClient(tokenProvider: tokenProvider, transport: transport)
        do {
            let monitoring = try await monitoringClient.fetchGeminiAPIRequests(
                projectID: settings.monitoringProjectID,
                period: period,
                updatedAt: now)
            let requests = monitoring.geminiAPI?.requestCount ?? 0
            let detail = monitoring.latestSampleDate.map { "latestSample=\($0)" }
            steps.append(.success(
                id: "monitoring",
                title: "Cloud Monitoring",
                message: "Gemini API request metrics are queryable (\(requests) requests in period).",
                detail: detail))
        } catch {
            steps.append(.warning(
                id: "monitoring",
                title: "Cloud Monitoring",
                message: Self.message(error),
                detail: "Billing can still work without Monitoring. Check roles/monitoring.viewer and Monitoring API enablement."))
        }

        return GoogleCloudDoctorReport(checkedAt: now, steps: steps)
    }

    private static func message(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription
        {
            return description
        }
        return error.localizedDescription
    }

    private static func bigQueryHint(_ error: Error) -> String? {
        switch error {
        case GoogleCloudUsageError.datasetNotFound:
            return "Check the billing dataset id and dataset-level read access."
        case GoogleCloudUsageError.billingExportTableNotFound:
            return "Enable Cloud Billing export or set the table override."
        case GoogleCloudUsageError.emptyBillingExport:
            return "The export may still be backfilling, or there may be no charges in the current month."
        default:
            return "Check roles/bigquery.jobUser on the billing project and dataset/table read access."
        }
    }

    private static func redactedEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return "<redacted>" }
        let prefix = email[..<at]
        let suffix = email[at...]
        return "\(prefix.prefix(2))***\(suffix)"
    }
}

private extension GoogleCloudDoctorStep {
    static func success(id: String, title: String, message: String, detail: String? = nil) -> Self {
        Self(id: id, title: title, status: .success, message: message, detail: detail)
    }

    static func warning(id: String, title: String, message: String, detail: String? = nil) -> Self {
        Self(id: id, title: title, status: .warning, message: message, detail: detail)
    }

    static func failure(id: String, title: String, message: String, detail: String? = nil) -> Self {
        Self(id: id, title: title, status: .failure, message: message, detail: detail)
    }

    static func skipped(id: String, title: String, message: String, detail: String? = nil) -> Self {
        Self(id: id, title: title, status: .skipped, message: message, detail: detail)
    }
}
