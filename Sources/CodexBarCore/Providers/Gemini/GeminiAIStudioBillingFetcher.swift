import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import AppKit
import WebKit
#endif

public enum GeminiAIStudioBillingPlan: String, Codable, Sendable {
    case free
    case prepay
    case postpay
    case unknown
}

public struct GeminiAIStudioBillingSnapshot: Codable, Equatable, Sendable {
    public let plan: GeminiAIStudioBillingPlan
    public let availableCredits: Double?
    public let monthToDateSpend: Double?
    public let spendCap: Double?

    public init(
        plan: GeminiAIStudioBillingPlan,
        availableCredits: Double? = nil,
        monthToDateSpend: Double? = nil,
        spendCap: Double? = nil)
    {
        self.plan = plan
        self.availableCredits = availableCredits
        self.monthToDateSpend = monthToDateSpend
        self.spendCap = spendCap
    }
}

public struct GeminiAIStudioUsageSnapshot: Codable, Equatable, Sendable {
    public let requestCount: Int?
    public let inputTokenCount: Int?
    public let outputTokenCount: Int?

    public var totalTokenCount: Int? {
        switch (self.inputTokenCount, self.outputTokenCount) {
        case let (input?, output?): input + output
        case let (input?, nil): input
        case let (nil, output?): output
        case (nil, nil): nil
        }
    }

    public init(requestCount: Int? = nil, inputTokenCount: Int? = nil, outputTokenCount: Int? = nil) {
        self.requestCount = requestCount
        self.inputTokenCount = inputTokenCount
        self.outputTokenCount = outputTokenCount
    }
}

public struct GeminiAIStudioScrapeSnapshot: Codable, Equatable, Sendable {
    public let billing: GeminiAIStudioBillingSnapshot
    public let usage: GeminiAIStudioUsageSnapshot

    public init(
        billing: GeminiAIStudioBillingSnapshot = GeminiAIStudioBillingSnapshot(plan: .unknown),
        usage: GeminiAIStudioUsageSnapshot = GeminiAIStudioUsageSnapshot())
    {
        self.billing = billing
        self.usage = usage
    }
}

public struct GeminiAIStudioScrapeFetcher: Sendable {
    public typealias PageTextLoader = @Sendable (URL) async throws -> String
    public typealias ContextResolver = @Sendable (String) async throws -> GeminiAIStudioContext

    private let pageTextLoader: PageTextLoader
    private let contextResolver: ContextResolver?

    public init(
        pageTextLoader: @escaping PageTextLoader = Self.defaultPageTextLoader,
        contextResolver: ContextResolver? = nil)
    {
        self.pageTextLoader = pageTextLoader
        self.contextResolver = contextResolver
    }

    public func scrape(apiKey: String) async throws -> GeminiAIStudioScrapeSnapshot {
        let context = try await self.contextResolver?(apiKey)
        let usageURL = context?.usageURL ?? URL(string: "https://aistudio.google.com/usage")!
        let billingURL = context?.billingURL ?? URL(string: "https://aistudio.google.com/billing")!

        async let usageText = self.pageTextLoader(usageURL)
        async let billingText = self.pageTextLoader(billingURL)
        return try await GeminiAIStudioScrapeSnapshot(
            billing: GeminiAIStudioBillingParser.parseBillingPageText(billingText),
            usage: GeminiAIStudioBillingParser.parseUsagePageText(usageText))
    }

    public static func defaultPageTextLoader(_ url: URL) async throws -> String {
        #if os(macOS)
        return try await GeminiAIStudioWebPageTextLoader.loadText(from: url)
        #else
        var request = URLRequest(url: url)
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GeminiAIStudioBillingError.httpError(statusCode: http.statusCode, body: body)
        }
        return String(data: data, encoding: .utf8) ?? ""
        #endif
    }
}

#if os(macOS)
@MainActor
private final class GeminiAIStudioWebPageTextLoader: NSObject, WKNavigationDelegate {
    private enum LoadError: LocalizedError {
        case timedOut
        case noContinuation

        var errorDescription: String? {
            switch self {
            case .timedOut:
                "Timed out loading AI Studio."
            case .noContinuation:
                "AI Studio page loader was not initialized."
            }
        }
    }

    private let url: URL
    private var continuation: CheckedContinuation<String, any Error>?
    private var didComplete = false
    private var window: NSWindow?
    private var webView: WKWebView?

    private init(url: URL) {
        self.url = url
    }

    static func loadText(from url: URL, timeout: TimeInterval = 30) async throws -> String {
        let loader = GeminiAIStudioWebPageTextLoader(url: url)
        return try await loader.load(timeout: timeout)
    }

    private func load(timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.start()

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(.failure(LoadError.timedOut))
            }
        }
    }

    private func start() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        let window = NSWindow(
            contentRect: CGRect(x: -10000, y: -10000, width: 1200, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.alphaValue = 0.001
        window.contentView = webView
        window.orderFrontRegardless()
        self.window = window

        var request = URLRequest(url: self.url)
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        webView.load(request)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, let webView else { return }
            do {
                let result = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")
                self.finish(.success((result as? String) ?? ""))
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        self.finish(.failure(error))
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
        self.finish(.failure(error))
    }

    private func finish(_ result: Result<String, any Error>) {
        guard !self.didComplete else { return }
        self.didComplete = true
        self.webView?.navigationDelegate = nil
        self.webView?.stopLoading()
        self.webView = nil
        self.window?.orderOut(nil)
        self.window = nil

        guard let continuation = self.continuation else { return }
        self.continuation = nil
        switch result {
        case let .success(text):
            continuation.resume(returning: text)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
#endif

private struct CloudMonitoringTimeSeriesResponse: Decodable {
    let timeSeries: [CloudMonitoringTimeSeries]?
}

private struct CloudMonitoringTimeSeries: Decodable {
    let points: [CloudMonitoringPoint]?
}

private struct CloudMonitoringPoint: Decodable {
    let value: CloudMonitoringTypedValue?
}

private struct CloudMonitoringTypedValue: Decodable {
    let int64Value: String?
    let doubleValue: Double?
}

public struct GeminiAIStudioContext: Codable, Equatable, Sendable {
    public let projectNumber: String
    public let projectID: String
    public let billingAccountID: String?
    public let billingEnabled: Bool

    public var billingURL: URL? {
        guard let billingAccountID else { return nil }
        return URL(string: "https://aistudio.google.com/billing?billing=\(billingAccountID)")
    }

    public var usageURL: URL {
        URL(string: "https://aistudio.google.com/usage?project=\(self.projectID)")!
    }

    public init(projectNumber: String, projectID: String, billingAccountID: String?, billingEnabled: Bool) {
        self.projectNumber = projectNumber
        self.projectID = projectID
        self.billingAccountID = billingAccountID
        self.billingEnabled = billingEnabled
    }
}

public enum GeminiAIStudioBillingError: LocalizedError, Sendable {
    case missingAccessToken
    case malformedLookupResponse
    case malformedBillingResponse
    case httpError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            "Google auth is required to resolve Gemini API key billing. Run `gcloud auth login` or sign in."
        case .malformedLookupResponse:
            "Could not resolve the Gemini API key to a Google Cloud project."
        case .malformedBillingResponse:
            "Could not resolve the Gemini project billing account."
        case let .httpError(statusCode, body):
            "Google billing lookup failed (HTTP \(statusCode)): \(body.prefix(200))"
        }
    }
}

public struct GeminiAIStudioBillingFetcher: Sendable {
    public typealias AccessTokenProvider = @Sendable () async throws -> String
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let accessTokenProvider: AccessTokenProvider
    private let dataLoader: DataLoader

    public init(
        accessTokenProvider: @escaping AccessTokenProvider = Self.defaultAccessToken,
        dataLoader: @escaping DataLoader = Self.defaultDataLoader)
    {
        self.accessTokenProvider = accessTokenProvider
        self.dataLoader = dataLoader
    }

    public func resolveContext(apiKey: String) async throws -> GeminiAIStudioContext {
        let token = try await self.accessTokenProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GeminiAIStudioBillingError.missingAccessToken }

        let projectNumber = try await self.lookupProjectNumber(apiKey: apiKey, accessToken: token)
        return try await self.lookupBillingInfo(projectNumber: projectNumber, accessToken: token)
    }

    public func fetchDailyUsage(projectID: String) async throws -> GeminiAIStudioUsageSnapshot {
        let token = try await self.accessTokenProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GeminiAIStudioBillingError.missingAccessToken }

        let now = Date()
        let start = Calendar(identifier: .gregorian).startOfDay(for: now)
        var components = URLComponents(string: "https://monitoring.googleapis.com/v3/projects/\(projectID)/timeSeries")!
        components.queryItems = [
            URLQueryItem(
                name: "filter",
                value: "metric.type=\"serviceruntime.googleapis.com/api/request_count\" AND resource.labels.service=\"generativelanguage.googleapis.com\""),
            URLQueryItem(name: "interval.startTime", value: Self.iso8601String(from: start)),
            URLQueryItem(name: "interval.endTime", value: Self.iso8601String(from: now)),
            URLQueryItem(name: "aggregation.alignmentPeriod", value: "86400s"),
            URLQueryItem(name: "aggregation.perSeriesAligner", value: "ALIGN_DELTA"),
            URLQueryItem(name: "aggregation.crossSeriesReducer", value: "REDUCE_SUM"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data = try await self.loadSuccessfulData(request)
        let response = try JSONDecoder().decode(CloudMonitoringTimeSeriesResponse.self, from: data)
        let requestCount = response.timeSeries?.reduce(0) { total, series in
            total + (series.points ?? []).reduce(0) { pointTotal, point in
                if let int64 = point.value?.int64Value, let value = Int(int64) {
                    return pointTotal + value
                }
                if let double = point.value?.doubleValue {
                    return pointTotal + Int(double.rounded())
                }
                return pointTotal
            }
        }
        return GeminiAIStudioUsageSnapshot(requestCount: requestCount)
    }

    private func lookupProjectNumber(apiKey: String, accessToken: String) async throws -> String {
        var components = URLComponents(string: "https://apikeys.googleapis.com/v2/keys:lookupKey")!
        components.queryItems = [URLQueryItem(name: "keyString", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data = try await self.loadSuccessfulData(request)
        let response = try JSONDecoder().decode(APIKeyLookupResponse.self, from: data)
        guard let projectNumber = response.projectNumber else {
            throw GeminiAIStudioBillingError.malformedLookupResponse
        }
        return projectNumber
    }

    private func lookupBillingInfo(projectNumber: String, accessToken: String) async throws -> GeminiAIStudioContext {
        let url = URL(string: "https://cloudbilling.googleapis.com/v1/projects/\(projectNumber)/billingInfo")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data = try await self.loadSuccessfulData(request)
        let response = try JSONDecoder().decode(ProjectBillingInfoResponse.self, from: data)
        guard let projectID = response.projectIDFromNameOrField else {
            throw GeminiAIStudioBillingError.malformedBillingResponse
        }
        return GeminiAIStudioContext(
            projectNumber: projectNumber,
            projectID: projectID,
            billingAccountID: response.billingAccountID,
            billingEnabled: response.billingEnabled)
    }

    private func loadSuccessfulData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await self.dataLoader(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GeminiAIStudioBillingError.httpError(statusCode: http.statusCode, body: body)
        }
        return data
    }

    public static func defaultAccessToken() async throws -> String {
        try await GeminiStatusProbe.currentOAuthAccessToken()
    }

    public static func defaultDataLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct APIKeyLookupResponse: Decodable {
    let parent: String?

    var projectNumber: String? {
        guard let parent else { return nil }
        let parts = parent.split(separator: "/")
        guard parts.count >= 2, parts[0] == "projects" else { return nil }
        return String(parts[1])
    }
}

private struct ProjectBillingInfoResponse: Decodable {
    let name: String?
    let projectId: String?
    let billingAccountName: String?
    let billingEnabled: Bool

    var projectIDFromNameOrField: String? {
        if let projectId, !projectId.isEmpty { return projectId }
        guard let name else { return nil }
        let parts = name.split(separator: "/")
        guard parts.count >= 2, parts[0] == "projects" else { return nil }
        return String(parts[1])
    }

    var billingAccountID: String? {
        guard let billingAccountName, !billingAccountName.isEmpty else { return nil }
        let prefix = "billingAccounts/"
        if billingAccountName.hasPrefix(prefix) {
            return String(billingAccountName.dropFirst(prefix.count))
        }
        return billingAccountName
    }
}

public enum GeminiAIStudioBillingParser {
    public static func parseBillingPageText(_ text: String) -> GeminiAIStudioBillingSnapshot {
        let lower = text.lowercased()
        let plan: GeminiAIStudioBillingPlan = if lower.contains("prepay") || lower
            .contains("available credits") || lower.contains("buy credits")
        {
            .prepay
        } else if lower.contains("postpay") || lower.contains("current balance") || lower
            .contains("monthly spend cap")
        {
            .postpay
        } else if lower.contains("set up billing") || lower.contains("free tier") {
            .free
        } else {
            .unknown
        }

        return GeminiAIStudioBillingSnapshot(
            plan: plan,
            availableCredits: self.amount(
                after: ["available credits", "credit balance", "credits remaining"],
                in: text),
            monthToDateSpend: self.amount(after: ["spend this month", "current balance", "monthly spend"], in: text),
            spendCap: self.amount(after: ["monthly spend cap", "spend cap"], in: text))
    }

    public static func parseUsagePageText(_ text: String) -> GeminiAIStudioUsageSnapshot {
        GeminiAIStudioUsageSnapshot(
            requestCount: self.integer(after: ["api requests", "requests"], in: text),
            inputTokenCount: self.integer(after: ["input tokens", "prompt tokens"], in: text),
            outputTokenCount: self.integer(after: ["output tokens", "candidate tokens", "completion tokens"], in: text))
    }

    private static func amount(after labels: [String], in text: String) -> Double? {
        for label in labels {
            if let value = self.number(after: label, in: text) { return value }
        }
        return nil
    }

    private static func integer(after labels: [String], in text: String) -> Int? {
        for label in labels {
            if let value = self.number(after: label, in: text) { return Int(value.rounded()) }
        }
        return nil
    }

    private static func number(after label: String, in text: String) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = "(?is)\(escaped)[^0-9$€£¥-]*[$€£¥]?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Double(text[valueRange].replacingOccurrences(of: ",", with: ""))
    }
}
