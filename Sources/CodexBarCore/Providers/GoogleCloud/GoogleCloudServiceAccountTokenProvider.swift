import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import _CryptoExtras

public enum GoogleCloudUsageError: LocalizedError, Sendable, Equatable {
    case missingSetting(String)
    case missingCredentials
    case invalidServiceAccountJSON
    case tokenExchangeFailed(Int)
    case invalidIdentifier(String)
    case datasetNotFound
    case billingExportTableNotFound
    case emptyBillingExport
    case bigQueryError(String)
    case monitoringError(String)
    case parseFailed(String)
    case multipleCurrencies([String])

    public var errorDescription: String? {
        switch self {
        case let .missingSetting(name):
            "Missing Google Cloud \(name)."
        case .missingCredentials:
            "Missing Google Cloud service account JSON path. Set GOOGLE_APPLICATION_CREDENTIALS or configure Google Cloud in Settings."
        case .invalidServiceAccountJSON:
            "Invalid Google Cloud service account JSON."
        case let .tokenExchangeFailed(statusCode):
            "Google Cloud token exchange failed: HTTP \(statusCode)."
        case let .invalidIdentifier(name):
            "Invalid Google Cloud BigQuery identifier: \(name)."
        case .datasetNotFound:
            "Google Cloud billing export dataset was not found."
        case .billingExportTableNotFound:
            "Google Cloud billing export table was not found."
        case .emptyBillingExport:
            "Google Cloud billing export has no rows for the selected period."
        case let .bigQueryError(message):
            "Google Cloud BigQuery query failed: \(message)"
        case let .monitoringError(message):
            "Google Cloud Monitoring query failed: \(message)"
        case let .parseFailed(message):
            "Failed to parse Google Cloud response: \(message)"
        case let .multipleCurrencies(currencies):
            "Google Cloud billing export returned multiple currencies: \(currencies.joined(separator: ", "))."
        }
    }
}

public struct GoogleCloudServiceAccount: Sendable, Equatable {
    public let clientEmail: String
    public let privateKey: String
    public let tokenURI: URL

    public init(clientEmail: String, privateKey: String, tokenURI: URL) {
        self.clientEmail = clientEmail
        self.privateKey = privateKey
        self.tokenURI = tokenURI
    }

    public static func load(path rawPath: String?) throws -> GoogleCloudServiceAccount {
        guard let rawPath = GoogleCloudSettingsReader.cleaned(rawPath) else {
            throw GoogleCloudUsageError.missingCredentials
        }
        let path = (rawPath as NSString).expandingTildeInPath
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode(ServiceAccountJSON.self, from: data)
        guard decoded.type == "service_account",
              let tokenURI = URL(string: decoded.tokenURI),
              !decoded.clientEmail.isEmpty,
              !decoded.privateKey.isEmpty
        else {
            throw GoogleCloudUsageError.invalidServiceAccountJSON
        }
        return GoogleCloudServiceAccount(
            clientEmail: decoded.clientEmail,
            privateKey: decoded.privateKey.replacingOccurrences(of: "\\n", with: "\n"),
            tokenURI: tokenURI)
    }

    private struct ServiceAccountJSON: Decodable {
        let type: String
        let clientEmail: String
        let privateKey: String
        let tokenURI: String

        private enum CodingKeys: String, CodingKey {
            case type
            case clientEmail = "client_email"
            case privateKey = "private_key"
            case tokenURI = "token_uri"
        }
    }
}

public actor GoogleCloudServiceAccountTokenProvider {
    private struct CacheKey: Hashable {
        let clientEmail: String
        let scopes: String
    }

    private struct CachedToken {
        let accessToken: String
        let expiresAt: Date
    }

    private let account: GoogleCloudServiceAccount
    private let transport: any ProviderHTTPTransport
    private let now: @Sendable () -> Date
    private var cache: [CacheKey: CachedToken] = [:]

    public init(
        account: GoogleCloudServiceAccount,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.account = account
        self.transport = transport
        self.now = now
    }

    public func accessToken(scopes: [String]) async throws -> String {
        let normalizedScopes = scopes.sorted()
        let cacheKey = CacheKey(clientEmail: self.account.clientEmail, scopes: normalizedScopes.joined(separator: " "))
        let now = self.now()
        if let cached = self.cache[cacheKey],
           cached.expiresAt.timeIntervalSince(now) > 120
        {
            return cached.accessToken
        }

        let assertion = try Self.jwtAssertion(
            account: self.account,
            scopes: normalizedScopes,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(3600))
        let body = Self.formURLEncoded([
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        ])
        var request = URLRequest(url: self.account.tokenURI)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let response = try await self.transport.response(for: request, retryPolicy: .transientIdempotent)
        guard response.statusCode == 200 else {
            throw GoogleCloudUsageError.tokenExchangeFailed(response.statusCode)
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: response.data)
        let expiresAt = now.addingTimeInterval(TimeInterval(max(60, token.expiresIn)))
        self.cache[cacheKey] = CachedToken(accessToken: token.accessToken, expiresAt: expiresAt)
        return token.accessToken
    }

    static func jwtAssertion(
        account: GoogleCloudServiceAccount,
        scopes: [String],
        issuedAt: Date,
        expiresAt: Date) throws -> String
    {
        let header = ["alg": "RS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "iss": account.clientEmail,
            "scope": scopes.sorted().joined(separator: " "),
            "aud": account.tokenURI.absoluteString,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "exp": Int(expiresAt.timeIntervalSince1970),
        ]
        let signingInput = try [
            Self.base64URLEncodedJSON(header),
            Self.base64URLEncodedJSON(payload),
        ].joined(separator: ".")

        let key = try _RSA.Signing.PrivateKey(pemRepresentation: account.privateKey)
        let digest = SHA256.hash(data: Data(signingInput.utf8))
        let signature = try key.signature(for: digest, padding: .insecurePKCS1v1_5)
        return signingInput + "." + Self.base64URLEncoded(signature.rawRepresentation)
    }

    private static func base64URLEncodedJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return self.base64URLEncoded(data)
    }

    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formURLEncoded(_ values: [String: String]) -> String {
        values.map { key, value in
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))
            return "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        .sorted()
        .joined(separator: "&")
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }
}
