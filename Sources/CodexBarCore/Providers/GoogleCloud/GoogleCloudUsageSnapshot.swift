import Foundation

public struct GoogleCloudUsageSnapshot: Codable, Sendable {
    public let period: GoogleCloudBillingPeriod
    public let currencyCode: String
    public let grossCost: Double
    public let credits: Double
    public let netCost: Double
    public let rows: [GoogleCloudCostRow]
    public let monitoring: GoogleCloudMonitoringSnapshot?
    public let monitoringStatus: GoogleCloudMonitoringStatus
    public let warnings: [String]
    public let exportTable: String
    public let exportKind: GoogleCloudBillingExportKind
    public let billingLatestUsageDate: String?
    public let updatedAt: Date

    public init(
        period: GoogleCloudBillingPeriod,
        currencyCode: String,
        grossCost: Double,
        credits: Double,
        netCost: Double,
        rows: [GoogleCloudCostRow],
        monitoring: GoogleCloudMonitoringSnapshot?,
        monitoringStatus: GoogleCloudMonitoringStatus,
        warnings: [String],
        exportTable: String,
        exportKind: GoogleCloudBillingExportKind,
        billingLatestUsageDate: String? = nil,
        updatedAt: Date)
    {
        self.period = period
        self.currencyCode = currencyCode
        self.grossCost = grossCost
        self.credits = credits
        self.netCost = netCost
        self.rows = rows
        self.monitoring = monitoring
        self.monitoringStatus = monitoringStatus
        self.warnings = warnings
        self.exportTable = exportTable
        self.exportKind = exportKind
        self.billingLatestUsageDate = billingLatestUsageDate
        self.updatedAt = updatedAt
    }

    public var geminiAPI: GoogleCloudCostRow? {
        self.rows.first { $0.id == GoogleCloudCostRow.geminiAPIID }
    }

    public func toUsageSnapshot(budget: Double?) -> UsageSnapshot {
        let budget = budget.flatMap { $0 > 0 ? $0 : nil }
        let primary = budget.map { value in
            RateWindow(
                usedPercent: min(100, max(0, (self.netCost / value) * 100)),
                windowMinutes: nil,
                resetsAt: self.period.endDateValue,
                resetDescription: self.period.label)
        }
        let cost = ProviderCostSnapshot(
            used: self.netCost,
            limit: budget ?? 0,
            currencyCode: self.currencyCode,
            period: self.period.label,
            resetsAt: self.period.endDateValue,
            updatedAt: self.updatedAt)
        let identity = ProviderIdentitySnapshot(
            providerID: .googlecloud,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.monitoringStatus == .available ? "bigquery-billing + monitoring" : "bigquery-billing")
        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: cost,
            googleCloudUsage: self,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public struct GoogleCloudBillingPeriod: Codable, Sendable, Equatable {
    public let startDate: String
    public let endDate: String
    public let label: String

    public init(startDate: String, endDate: String, label: String) {
        self.startDate = startDate
        self.endDate = endDate
        self.label = label
    }

    var endDateValue: Date? {
        Self.makeDateFormatter().date(from: self.endDate)
    }

    static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

public enum GoogleCloudBillingExportKind: String, Codable, Sendable {
    case detailed
    case standard
    case focus
}

public enum GoogleCloudCostRowKind: String, Codable, Sendable {
    case service
    case project
    case sku
    case label
    case special
}

public enum GoogleCloudMonitoringStatus: String, Codable, Sendable {
    case disabled
    case available
    case unavailable
}

public struct GoogleCloudCostRow: Codable, Sendable {
    public static let geminiAPIID = "gemini-api"

    public let id: String
    public let title: String
    public let kind: GoogleCloudCostRowKind
    public let serviceID: String?
    public let serviceDescription: String?
    public let projectID: String?
    public let projectName: String?
    public let skuDescription: String?
    public let labelKey: String?
    public let labelValue: String?
    public let grossCost: Double
    public let credits: Double
    public let netCost: Double
    public let usageAmount: Double?
    public let usageUnit: String?
    public let requestCount: Int?
    public let successfulRequestCount: Int?
    public let errorRequestCount: Int?
    public let monitoringBreakdown: GoogleCloudMonitoringBreakdown?
    public let percentOfTotal: Double

    public init(
        id: String,
        title: String,
        kind: GoogleCloudCostRowKind,
        serviceID: String? = nil,
        serviceDescription: String? = nil,
        projectID: String? = nil,
        projectName: String? = nil,
        skuDescription: String? = nil,
        labelKey: String? = nil,
        labelValue: String? = nil,
        grossCost: Double,
        credits: Double,
        netCost: Double,
        usageAmount: Double? = nil,
        usageUnit: String? = nil,
        requestCount: Int? = nil,
        successfulRequestCount: Int? = nil,
        errorRequestCount: Int? = nil,
        monitoringBreakdown: GoogleCloudMonitoringBreakdown? = nil,
        percentOfTotal: Double)
    {
        self.id = id
        self.title = title
        self.kind = kind
        self.serviceID = serviceID
        self.serviceDescription = serviceDescription
        self.projectID = projectID
        self.projectName = projectName
        self.skuDescription = skuDescription
        self.labelKey = labelKey
        self.labelValue = labelValue
        self.grossCost = grossCost
        self.credits = credits
        self.netCost = netCost
        self.usageAmount = usageAmount
        self.usageUnit = usageUnit
        self.requestCount = requestCount
        self.successfulRequestCount = successfulRequestCount
        self.errorRequestCount = errorRequestCount
        self.monitoringBreakdown = monitoringBreakdown
        self.percentOfTotal = percentOfTotal
    }
}

public struct GoogleCloudMonitoringSnapshot: Codable, Sendable {
    public let period: GoogleCloudBillingPeriod
    public let projectID: String
    public let services: [GoogleCloudMonitoredService]
    public let warnings: [String]
    public let latestSampleDate: String?
    public let updatedAt: Date

    public init(
        period: GoogleCloudBillingPeriod,
        projectID: String,
        services: [GoogleCloudMonitoredService],
        warnings: [String],
        latestSampleDate: String? = nil,
        updatedAt: Date)
    {
        self.period = period
        self.projectID = projectID
        self.services = services
        self.warnings = warnings
        self.latestSampleDate = latestSampleDate
        self.updatedAt = updatedAt
    }

    public var geminiAPI: GoogleCloudMonitoredService? {
        self.services.first { $0.id == GoogleCloudCostRow.geminiAPIID }
    }
}

public struct GoogleCloudMonitoredService: Codable, Sendable {
    public let id: String
    public let title: String
    public let requestCount: Int
    public let successfulRequestCount: Int
    public let errorRequestCount: Int
    public let credentials: [GoogleCloudCredentialUsage]
    public let methods: [GoogleCloudMethodUsage]
    public let responseCodes: [GoogleCloudResponseCodeUsage]
    public let dailyRequests: [GoogleCloudDailyRequestUsage]
    public let latestSampleDate: String?

    public init(
        id: String,
        title: String,
        requestCount: Int,
        successfulRequestCount: Int,
        errorRequestCount: Int,
        credentials: [GoogleCloudCredentialUsage],
        methods: [GoogleCloudMethodUsage],
        responseCodes: [GoogleCloudResponseCodeUsage],
        dailyRequests: [GoogleCloudDailyRequestUsage],
        latestSampleDate: String? = nil)
    {
        self.id = id
        self.title = title
        self.requestCount = requestCount
        self.successfulRequestCount = successfulRequestCount
        self.errorRequestCount = errorRequestCount
        self.credentials = credentials
        self.methods = methods
        self.responseCodes = responseCodes
        self.dailyRequests = dailyRequests
        self.latestSampleDate = latestSampleDate
    }

    public var breakdown: GoogleCloudMonitoringBreakdown {
        GoogleCloudMonitoringBreakdown(
            credentials: self.credentials,
            methods: self.methods,
            responseCodes: self.responseCodes,
            dailyRequests: self.dailyRequests)
    }
}

public struct GoogleCloudMonitoringBreakdown: Codable, Sendable {
    public let credentials: [GoogleCloudCredentialUsage]
    public let methods: [GoogleCloudMethodUsage]
    public let responseCodes: [GoogleCloudResponseCodeUsage]
    public let dailyRequests: [GoogleCloudDailyRequestUsage]

    public init(
        credentials: [GoogleCloudCredentialUsage],
        methods: [GoogleCloudMethodUsage],
        responseCodes: [GoogleCloudResponseCodeUsage],
        dailyRequests: [GoogleCloudDailyRequestUsage])
    {
        self.credentials = credentials
        self.methods = methods
        self.responseCodes = responseCodes
        self.dailyRequests = dailyRequests
    }
}

public struct GoogleCloudCredentialUsage: Codable, Sendable {
    public let credentialID: String
    public let displayID: String
    public let requestCount: Int
    public let successfulRequestCount: Int
    public let errorRequestCount: Int

    public init(
        credentialID: String,
        displayID: String,
        requestCount: Int,
        successfulRequestCount: Int,
        errorRequestCount: Int)
    {
        self.credentialID = credentialID
        self.displayID = displayID
        self.requestCount = requestCount
        self.successfulRequestCount = successfulRequestCount
        self.errorRequestCount = errorRequestCount
    }
}

public struct GoogleCloudMethodUsage: Codable, Sendable {
    public let method: String
    public let requestCount: Int
    public let successfulRequestCount: Int
    public let errorRequestCount: Int

    public init(method: String, requestCount: Int, successfulRequestCount: Int, errorRequestCount: Int) {
        self.method = method
        self.requestCount = requestCount
        self.successfulRequestCount = successfulRequestCount
        self.errorRequestCount = errorRequestCount
    }
}

public struct GoogleCloudResponseCodeUsage: Codable, Sendable {
    public let responseCode: String
    public let requestCount: Int

    public init(responseCode: String, requestCount: Int) {
        self.responseCode = responseCode
        self.requestCount = requestCount
    }
}

public struct GoogleCloudDailyRequestUsage: Codable, Sendable {
    public let date: String
    public let requestCount: Int
    public let successfulRequestCount: Int
    public let errorRequestCount: Int

    public init(date: String, requestCount: Int, successfulRequestCount: Int, errorRequestCount: Int) {
        self.date = date
        self.requestCount = requestCount
        self.successfulRequestCount = successfulRequestCount
        self.errorRequestCount = errorRequestCount
    }
}
