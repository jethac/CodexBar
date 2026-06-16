import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class GoogleCloudMonitoringClient: @unchecked Sendable {
    public static let readonlyScope = "https://www.googleapis.com/auth/monitoring.read"

    private let tokenProvider: GoogleCloudServiceAccountTokenProvider
    private let transport: any ProviderHTTPTransport
    private let baseURL: URL

    public init(
        tokenProvider: GoogleCloudServiceAccountTokenProvider,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        baseURL: URL = URL(string: "https://monitoring.googleapis.com")!)
    {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.baseURL = baseURL
    }

    public func fetchGeminiAPIRequests(
        projectID: String,
        period: GoogleCloudBillingPeriod,
        updatedAt: Date = Date()) async throws -> GoogleCloudMonitoringSnapshot
    {
        let token = try await self.tokenProvider.accessToken(scopes: [Self.readonlyScope])
        let url = self.baseURL
            .appendingPathComponent("v3")
            .appendingPathComponent("projects")
            .appendingPathComponent(projectID)
            .appendingPathComponent("timeSeries")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(
                name: "filter",
                value: #"metric.type = "serviceruntime.googleapis.com/api/request_count" AND resource.labels.service = "generativelanguage.googleapis.com""#),
            URLQueryItem(name: "interval.startTime", value: "\(period.startDate)T00:00:00Z"),
            URLQueryItem(name: "interval.endTime", value: "\(period.endDate)T00:00:00Z"),
            URLQueryItem(name: "aggregation.alignmentPeriod", value: "86400s"),
            URLQueryItem(name: "aggregation.perSeriesAligner", value: "ALIGN_SUM"),
            URLQueryItem(name: "aggregation.groupByFields", value: "resource.labels.credential_id"),
            URLQueryItem(name: "aggregation.groupByFields", value: "resource.labels.method"),
            URLQueryItem(name: "aggregation.groupByFields", value: "metric.labels.response_code"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let response = try await self.transport.response(for: request, retryPolicy: .transientIdempotent)
        guard response.statusCode == 200 else {
            throw GoogleCloudUsageError.monitoringError("HTTP \(response.statusCode)")
        }
        let decoded = try JSONDecoder().decode(TimeSeriesResponse.self, from: response.data)
        let service = Self.aggregateGeminiService(decoded.timeSeries ?? [])
        return GoogleCloudMonitoringSnapshot(
            period: period,
            projectID: projectID,
            services: [service],
            warnings: [],
            latestSampleDate: service.latestSampleDate,
            updatedAt: updatedAt)
    }

    static func aggregateGeminiService(_ series: [MonitoringTimeSeries]) -> GoogleCloudMonitoredService {
        var total = Counter()
        var byCredential: [String: Counter] = [:]
        var byMethod: [String: Counter] = [:]
        var byResponseCode: [String: Int] = [:]
        var byDay: [String: Counter] = [:]
        var latestSampleDate: String?

        for item in series {
            let rawCredential = item.resource.labels["credential_id"] ?? "unknown"
            let credential = Self.normalizedCredentialID(rawCredential)
            let method = Self.shortMethod(item.resource.labels["method"] ?? "unknown")
            let responseCode = item.metric.labels["response_code"] ?? "unknown"
            let isSuccess = responseCode.hasPrefix("2")
            for point in item.points {
                let count = point.value.intValue
                guard count != 0 else { continue }
                let date = Self.day(from: point.interval.startTime ?? point.interval.endTime)
                if date != "unknown" {
                    if let currentLatest = latestSampleDate {
                        latestSampleDate = max(currentLatest, date)
                    } else {
                        latestSampleDate = date
                    }
                }
                total.add(count: count, success: isSuccess)
                byCredential[credential, default: Counter()].add(count: count, success: isSuccess)
                byMethod[method, default: Counter()].add(count: count, success: isSuccess)
                byResponseCode[responseCode, default: 0] += count
                byDay[date, default: Counter()].add(count: count, success: isSuccess)
            }
        }

        return GoogleCloudMonitoredService(
            id: GoogleCloudCostRow.geminiAPIID,
            title: "Gemini API",
            requestCount: total.total,
            successfulRequestCount: total.success,
            errorRequestCount: total.error,
            credentials: byCredential
                .map {
                    GoogleCloudCredentialUsage(
                        credentialID: $0.key,
                        displayID: Self.redactedCredentialID($0.key),
                        requestCount: $0.value.total,
                        successfulRequestCount: $0.value.success,
                        errorRequestCount: $0.value.error)
                }
                .sorted { $0.requestCount == $1.requestCount ? $0.displayID < $1.displayID : $0.requestCount > $1.requestCount },
            methods: byMethod
                .map {
                    GoogleCloudMethodUsage(
                        method: $0.key,
                        requestCount: $0.value.total,
                        successfulRequestCount: $0.value.success,
                        errorRequestCount: $0.value.error)
                }
                .sorted { $0.requestCount == $1.requestCount ? $0.method < $1.method : $0.requestCount > $1.requestCount },
            responseCodes: byResponseCode
                .map { GoogleCloudResponseCodeUsage(responseCode: $0.key, requestCount: $0.value) }
                .sorted { $0.responseCode < $1.responseCode },
            dailyRequests: byDay
                .map {
                    GoogleCloudDailyRequestUsage(
                        date: $0.key,
                        requestCount: $0.value.total,
                        successfulRequestCount: $0.value.success,
                        errorRequestCount: $0.value.error)
                }
                .sorted { $0.date < $1.date },
            latestSampleDate: latestSampleDate)
    }

    static func normalizedCredentialID(_ raw: String) -> String {
        let cleaned = GoogleCloudSettingsReader.cleaned(raw) ?? "unknown"
        if cleaned.hasPrefix("apikey:") {
            return String(cleaned.dropFirst("apikey:".count))
        }
        return cleaned
    }

    static func redactedCredentialID(_ raw: String) -> String {
        let cleaned = Self.normalizedCredentialID(raw)
        guard cleaned.count > 4 else { return "****" }
        return "****" + String(cleaned.suffix(4))
    }

    static func shortMethod(_ raw: String) -> String {
        let cleaned = GoogleCloudSettingsReader.cleaned(raw) ?? "unknown"
        return cleaned.split(separator: ".").last.map(String.init) ?? cleaned
    }

    static func day(from timestamp: String?) -> String {
        guard let timestamp, timestamp.count >= 10 else { return "unknown" }
        return String(timestamp.prefix(10))
    }
}

private struct Counter: Sendable {
    var total = 0
    var success = 0

    var error: Int {
        max(0, self.total - self.success)
    }

    mutating func add(count: Int, success: Bool) {
        self.total += count
        if success {
            self.success += count
        }
    }
}

struct TimeSeriesResponse: Decodable, Sendable {
    let timeSeries: [MonitoringTimeSeries]?
}

struct MonitoringTimeSeries: Decodable, Sendable {
    let metric: MonitoringMetric
    let resource: MonitoringResource
    let points: [MonitoringPoint]
}

struct MonitoringMetric: Decodable, Sendable {
    let labels: [String: String]
}

struct MonitoringResource: Decodable, Sendable {
    let labels: [String: String]
}

struct MonitoringPoint: Decodable, Sendable {
    let interval: MonitoringInterval
    let value: MonitoringValue
}

struct MonitoringInterval: Decodable, Sendable {
    let startTime: String?
    let endTime: String?
}

struct MonitoringValue: Decodable, Sendable {
    let int64Value: String?
    let doubleValue: Double?

    var intValue: Int {
        if let int64Value, let int = Int(int64Value) {
            return int
        }
        if let doubleValue {
            return Int(doubleValue)
        }
        return 0
    }
}
