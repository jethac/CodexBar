import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
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
