import Foundation

struct CLIServeAuth: Sendable {
    let token: String?
    let pairing: CLIServePairing?

    init(token: String?, pairing: CLIServePairing? = nil) {
        self.token = token
        self.pairing = pairing
    }

    init(dashboardToken: String?, pairing: CLIServePairing? = nil) {
        self.init(token: dashboardToken, pairing: pairing)
    }

    func authorizeDataRequest(_ request: CLILocalHTTPRequest) -> Bool {
        guard let token else {
            guard let pairing else { return true }
            return pairing.authorize(request)
        }
        guard let authorization = request.headers["authorization"] else { return false }
        let normalized = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "Bearer \(token)" { return true }
        return self.pairing?.authorize(request) == true
    }

    func authorizeDashboardRequest(_ request: CLILocalHTTPRequest) -> Bool {
        self.authorizeDataRequest(request)
    }
}

enum CLIServeSecurity {
    static func bindHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "localhost" ? "127.0.0.1" : host
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "localhost" || normalized == "::1" { return true }
        if normalized.hasPrefix("127.") { return true }
        return normalized == "0:0:0:0:0:0:0:1"
    }

    static func requiresDashboardToken(host: String) -> Bool {
        !self.isLoopbackHost(host)
    }
}

struct CLIServePairing: Sendable {
    struct Challenge: Sendable {
        let id: String
        let code: String
        let choices: [String]
        let token: String
        let expiresAt: Date
    }

    struct DiscoveryPayload: Encodable {
        let schemaVersion: Int
        let service: String
        let auth: AuthPayload
    }

    struct AuthPayload: Encodable {
        let type: String
        let pairingId: String
        let choices: [String]
        let expiresInSeconds: Int
    }

    struct ClaimPayload: Encodable {
        let schemaVersion: Int
        let token: String
        let endpoint: String
    }

    let challenge: Challenge
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        let code = Self.randomCode()
        self.challenge = Challenge(
            id: UUID().uuidString,
            code: code,
            choices: Self.choices(containing: code),
            token: Self.randomToken(),
            expiresAt: .distantFuture)
    }

    func discoveryPayload() -> DiscoveryPayload {
        DiscoveryPayload(
            schemaVersion: 1,
            service: "codexbar-dashboard",
            auth: AuthPayload(
                type: "choice",
                pairingId: self.challenge.id,
                choices: self.challenge.choices,
                expiresInSeconds: 0))
    }

    func claimPayload(pairingID: String?, choice: String?) -> ClaimPayload? {
        guard pairingID == self.challenge.id else { return nil }
        guard choice?.trimmingCharacters(in: .whitespacesAndNewlines) == self.challenge.code else { return nil }
        return ClaimPayload(
            schemaVersion: 1,
            token: self.challenge.token,
            endpoint: "/dashboard/v1/snapshot")
    }

    func authorize(_ request: CLILocalHTTPRequest) -> Bool {
        guard let authorization = request.headers["authorization"] else { return false }
        return authorization.trimmingCharacters(in: .whitespacesAndNewlines) == "Bearer \(self.challenge.token)"
    }

    private static func randomCode() -> String {
        String(Int.random(in: 100...999))
    }

    private static func choices(containing code: String) -> [String] {
        var choices = Set([code])
        while choices.count < 3 {
            choices.insert(Self.randomCode())
        }
        return Array(choices).shuffled()
    }

    private static func randomToken() -> String {
        [UUID().uuidString, UUID().uuidString]
            .joined()
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }
}
