import Foundation

public struct GoogleCloudSettings: Equatable, Sendable {
    public let billingProjectID: String
    public let billingDatasetID: String
    public let billingTableID: String?
    public let monitoringProjectID: String
    public let serviceAccountJSONPath: String?
    public let monthlyBudget: Double?
    public let costLabelKey: String?
    public let topRowCount: Int
    public let monitoringEnabled: Bool

    public init(
        billingProjectID: String,
        billingDatasetID: String,
        billingTableID: String?,
        monitoringProjectID: String,
        serviceAccountJSONPath: String?,
        monthlyBudget: Double?,
        costLabelKey: String?,
        topRowCount: Int,
        monitoringEnabled: Bool)
    {
        self.billingProjectID = billingProjectID
        self.billingDatasetID = billingDatasetID
        self.billingTableID = billingTableID
        self.monitoringProjectID = monitoringProjectID
        self.serviceAccountJSONPath = serviceAccountJSONPath
        self.monthlyBudget = monthlyBudget
        self.costLabelKey = costLabelKey
        self.topRowCount = topRowCount
        self.monitoringEnabled = monitoringEnabled
    }
}

public enum GoogleCloudSettingsReader {
    public static let billingProjectIDKey = "CODEXBAR_GOOGLE_CLOUD_PROJECT_ID"
    public static let billingDatasetIDKey = "CODEXBAR_GOOGLE_CLOUD_BILLING_DATASET"
    public static let billingTableIDKey = "CODEXBAR_GOOGLE_CLOUD_BILLING_TABLE"
    public static let monitoringProjectIDKey = "CODEXBAR_GOOGLE_CLOUD_MONITORING_PROJECT_ID"
    public static let monitoringEnabledKey = "CODEXBAR_GOOGLE_CLOUD_MONITORING_ENABLED"
    public static let serviceAccountJSONPathKey = "CODEXBAR_GOOGLE_CLOUD_SERVICE_ACCOUNT_JSON"
    public static let googleApplicationCredentialsKey = "GOOGLE_APPLICATION_CREDENTIALS"
    public static let budgetKey = "CODEXBAR_GOOGLE_CLOUD_BUDGET"
    public static let costLabelKey = "CODEXBAR_GOOGLE_CLOUD_COST_LABEL"
    public static let topRowCountKey = "CODEXBAR_GOOGLE_CLOUD_TOP_N"

    public static func settings(environment: [String: String]) throws -> GoogleCloudSettings {
        guard let projectID = self.cleaned(environment[self.billingProjectIDKey]) else {
            throw GoogleCloudUsageError.missingSetting("billing project id")
        }
        guard let datasetID = self.cleaned(environment[self.billingDatasetIDKey]) else {
            throw GoogleCloudUsageError.missingSetting("billing dataset id")
        }
        let monitoringProjectID = self.cleaned(environment[self.monitoringProjectIDKey]) ?? projectID
        return GoogleCloudSettings(
            billingProjectID: projectID,
            billingDatasetID: datasetID,
            billingTableID: self.cleaned(environment[self.billingTableIDKey]),
            monitoringProjectID: monitoringProjectID,
            serviceAccountJSONPath: self.cleaned(environment[self.serviceAccountJSONPathKey])
                ?? self.cleaned(environment[self.googleApplicationCredentialsKey]),
            monthlyBudget: self.double(environment[self.budgetKey]),
            costLabelKey: self.cleaned(environment[self.costLabelKey]),
            topRowCount: self.topRowCount(environment[self.topRowCountKey]),
            monitoringEnabled: self.bool(environment[self.monitoringEnabledKey], defaultValue: true))
    }

    public static func hasRequiredSettings(environment: [String: String]) -> Bool {
        self.cleaned(environment[self.billingProjectIDKey]) != nil &&
            self.cleaned(environment[self.billingDatasetIDKey]) != nil &&
            (self.cleaned(environment[self.serviceAccountJSONPathKey]) != nil ||
                self.cleaned(environment[self.googleApplicationCredentialsKey]) != nil)
    }

    public static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func double(_ raw: String?) -> Double? {
        guard let value = self.cleaned(raw), let parsed = Double(value), parsed > 0 else { return nil }
        return parsed
    }

    private static func topRowCount(_ raw: String?) -> Int {
        guard let value = self.cleaned(raw), let parsed = Int(value) else { return 8 }
        return min(25, max(1, parsed))
    }

    private static func bool(_ raw: String?, defaultValue: Bool) -> Bool {
        guard let value = self.cleaned(raw)?.lowercased() else { return defaultValue }
        switch value {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }
}
