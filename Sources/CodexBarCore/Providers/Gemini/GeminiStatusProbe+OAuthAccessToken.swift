import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension GeminiStatusProbe {
    public static func currentOAuthAccessToken(
        homeDirectory: String = NSHomeDirectory(),
        timeout: TimeInterval = 10.0,
        now: Date = Date(),
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = Self
            .defaultDataLoader) async throws
        -> String
    {
        let creds = try Self.loadCredentials(homeDirectory: homeDirectory)
        if let accessToken = creds.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !accessToken.isEmpty,
           creds.expiryDate.map({ $0.timeIntervalSince(now) > 60 }) != false
        {
            return accessToken
        }
        guard let refreshToken = creds.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty
        else {
            throw GeminiStatusProbeError.notLoggedIn
        }
        return try await Self.refreshAccessToken(
            refreshToken: refreshToken,
            timeout: timeout,
            homeDirectory: homeDirectory,
            dataLoader: dataLoader)
    }
}
