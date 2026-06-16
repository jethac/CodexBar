import CodexBarCore
import Foundation

extension SettingsStore {
    var googleCloudBillingProjectID: String {
        get { self.configSnapshot.providerConfig(for: .googlecloud)?.sanitizedWorkspaceID ?? "" }
        set {
            self.updateProviderConfig(provider: .googlecloud) { entry in
                entry.workspaceID = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(provider: .googlecloud, field: "billingProjectID", value: newValue)
        }
    }

    var googleCloudBillingDatasetID: String {
        get { self.configSnapshot.providerConfig(for: .googlecloud)?.sanitizedRegion ?? "" }
        set {
            self.updateProviderConfig(provider: .googlecloud) { entry in
                entry.region = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(provider: .googlecloud, field: "billingDatasetID", value: newValue)
        }
    }

    var googleCloudBillingTableID: String {
        get { self.configSnapshot.providerConfig(for: .googlecloud)?.sanitizedEnterpriseHost ?? "" }
        set {
            self.updateProviderConfig(provider: .googlecloud) { entry in
                entry.enterpriseHost = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(provider: .googlecloud, field: "billingTableID", value: newValue)
        }
    }

    var googleCloudServiceAccountJSONPath: String {
        get { self.configSnapshot.providerConfig(for: .googlecloud)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .googlecloud) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .googlecloud, field: "serviceAccountJSONPath", value: newValue)
        }
    }

    var googleCloudMonitoringProjectID: String {
        get { self.configSnapshot.providerConfig(for: .googlecloud)?.sanitizedSecretKey ?? "" }
        set {
            self.updateProviderConfig(provider: .googlecloud) { entry in
                entry.secretKey = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(provider: .googlecloud, field: "monitoringProjectID", value: newValue)
        }
    }

    var googleCloudMonthlyBudget: String {
        get { self.configSnapshot.providerConfig(for: .googlecloud)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .googlecloud) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(provider: .googlecloud, field: "monthlyBudget", value: newValue)
        }
    }

    var googleCloudCostLabelKey: String {
        get { self.configSnapshot.providerConfig(for: .googlecloud)?.sanitizedAWSProfile ?? "" }
        set {
            self.updateProviderConfig(provider: .googlecloud) { entry in
                entry.awsProfile = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(provider: .googlecloud, field: "costLabelKey", value: newValue)
        }
    }

    var googleCloudTopRowCount: String {
        get { self.configSnapshot.providerConfig(for: .googlecloud)?.sanitizedAWSAuthMode ?? "8" }
        set {
            self.updateProviderConfig(provider: .googlecloud) { entry in
                entry.awsAuthMode = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(provider: .googlecloud, field: "topRowCount", value: newValue)
        }
    }

    var googleCloudMonitoringEnabled: Bool {
        get { self.configSnapshot.providerConfig(for: .googlecloud)?.extrasEnabled ?? true }
        set {
            self.updateProviderConfig(provider: .googlecloud) { entry in
                entry.extrasEnabled = newValue
            }
            self.logProviderModeChange(provider: .googlecloud, field: "monitoringEnabled", value: "\(newValue)")
        }
    }
}
