import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AiAndUsageError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case invalidAPIKey
    case insufficientCredits
    case rateLimited
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Missing ai& API key. Add one in Settings or set AIAND_API_KEY."
        case .invalidAPIKey:
            "ai& rejected the API key. Create a new key at console.aiand.com and update Settings."
        case .insufficientCredits:
            "ai& reports the organization is out of credits. Top up at console.aiand.com."
        case .rateLimited:
            "ai& rate limit exceeded. Usage will refresh on the next cycle."
        case let .apiError(statusCode):
            "ai& analytics API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse ai& usage: \(message)"
        }
    }
}

public struct AiAndUsageSnapshot: Sendable, Equatable {
    public let last30DaysCostUSD: Double
    public let updatedAt: Date

    public init(last30DaysCostUSD: Double, updatedAt: Date) {
        self.last30DaysCostUSD = last30DaysCostUSD
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // ai& is prepaid with no quota windows; spend is the only documented usage
        // signal, so no RateWindows are synthesized. limit 0 means "no cap".
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: self.last30DaysCostUSD,
                limit: 0,
                currencyCode: "USD",
                period: "Last 30 days",
                updatedAt: self.updatedAt),
            updatedAt: self.updatedAt,
            identity: nil,
            dataConfidence: .exact)
    }
}

public enum AiAndUsageFetcher {
    static let summaryURL = URL(string: "https://api.aiand.com/analytics/summary?range=30days")!
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        _ rawCredential: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> AiAndUsageSnapshot
    {
        guard let credential = AiAndSettingsReader.cleaned(rawCredential) else {
            throw AiAndUsageError.notConfigured
        }
        var request = URLRequest(url: self.summaryURL)
        request.httpMethod = "GET"
        request.timeoutInterval = self.requestTimeoutSeconds
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw self.error(statusCode: response.statusCode)
        }
        return try self.parseSummary(response.data, now: now)
    }

    private static func parseSummary(_ data: Data, now: Date) throws -> AiAndUsageSnapshot {
        let summary: SummaryPayload
        do {
            summary = try JSONDecoder().decode(SummaryPayload.self, from: data)
        } catch {
            throw AiAndUsageError.parseFailed(error.localizedDescription)
        }
        guard summary.costUSD.isFinite else {
            throw AiAndUsageError.parseFailed("cost_usd is not a finite number")
        }
        return AiAndUsageSnapshot(last30DaysCostUSD: summary.costUSD, updatedAt: now)
    }

    private static func error(statusCode: Int) -> AiAndUsageError {
        switch statusCode {
        case 401:
            .invalidAPIKey
        case 402:
            .insufficientCredits
        case 429:
            .rateLimited
        default:
            .apiError(statusCode)
        }
    }
}

private struct SummaryPayload: Decodable {
    let costUSD: Double

    enum CodingKeys: String, CodingKey {
        case costUSD = "cost_usd"
    }
}
