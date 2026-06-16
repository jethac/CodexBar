import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct GoogleCloudProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .googlecloud

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "billing" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.googleCloudBillingProjectID
        _ = settings.googleCloudBillingDatasetID
        _ = settings.googleCloudBillingTableID
        _ = settings.googleCloudServiceAccountJSONPath
        _ = settings.googleCloudMonitoringProjectID
        _ = settings.googleCloudMonthlyBudget
        _ = settings.googleCloudCostLabelKey
        _ = settings.googleCloudTopRowCount
        _ = settings.googleCloudMonitoringEnabled
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        GoogleCloudSettingsReader.hasRequiredSettings(environment: context.environment)
    }

    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        [
            ProviderSettingsToggleDescriptor(
                id: "googlecloud-monitoring-enabled",
                title: "Cloud Monitoring",
                subtitle: "Fetch Gemini API request counts, methods, credentials, and response codes.",
                binding: context.boolBinding(\.googleCloudMonitoringEnabled),
                statusText: nil,
                actions: [],
                isVisible: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "googlecloud-billing-project",
                title: "Billing project ID",
                subtitle: "Project used to run BigQuery jobs. Can also be set with CODEXBAR_GOOGLE_CLOUD_PROJECT_ID.",
                kind: .plain,
                placeholder: "my-billing-project",
                binding: context.stringBinding(\.googleCloudBillingProjectID),
                actions: [Self.consoleAction(id: "googlecloud-open-billing", title: "Open billing", url: "https://console.cloud.google.com/billing")],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "googlecloud-billing-dataset",
                title: "Billing dataset ID",
                subtitle: "Dataset containing Cloud Billing export tables.",
                kind: .plain,
                placeholder: "billing_export",
                binding: context.stringBinding(\.googleCloudBillingDatasetID),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "googlecloud-billing-table",
                title: "Billing table override",
                subtitle: "Optional. Leave blank to auto-detect detailed or standard Cloud Billing export tables.",
                kind: .plain,
                placeholder: "gcp_billing_export_resource_v1_...",
                binding: context.stringBinding(\.googleCloudBillingTableID),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "googlecloud-service-account-json",
                title: "Service account JSON",
                subtitle: "Choose a service account JSON file. Only the path is stored; GOOGLE_APPLICATION_CREDENTIALS is also supported.",
                kind: .plain,
                placeholder: "~/.config/gcloud/codexbar-billing.json",
                binding: context.stringBinding(\.googleCloudServiceAccountJSONPath),
                actions: [Self.serviceAccountJSONPickerAction(context: context)],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "googlecloud-monitoring-project",
                title: "Monitoring project ID",
                subtitle: "Optional. Defaults to billing project when left blank.",
                kind: .plain,
                placeholder: "my-metrics-project",
                binding: context.stringBinding(\.googleCloudMonitoringProjectID),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "googlecloud-monthly-budget",
                title: "Monthly budget",
                subtitle: "Optional manual budget amount for the current month.",
                kind: .plain,
                placeholder: "100",
                binding: context.stringBinding(\.googleCloudMonthlyBudget),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "googlecloud-cost-label",
                title: "Cost label key",
                subtitle: "Optional label grouping, for example cost_center, team, or env.",
                kind: .plain,
                placeholder: "cost_center",
                binding: context.stringBinding(\.googleCloudCostLabelKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "googlecloud-top-row-count",
                title: "Top row count",
                subtitle: "Number of child cost rows to show.",
                kind: .plain,
                placeholder: "8",
                binding: context.stringBinding(\.googleCloudTopRowCount),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }

    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry]) {
        guard let usage = context.snapshot?.googleCloudUsage else { return }
        var freshness: [String] = []
        if let latestSample = usage.monitoring?.latestSampleDate {
            freshness.append("Monitoring sample \(latestSample)")
        }
        if let latestBilling = usage.billingLatestUsageDate {
            freshness.append("Billing export \(latestBilling)")
        }
        if !freshness.isEmpty {
            entries.append(.text(freshness.joined(separator: " · "), .secondary))
        }
        if usage.monitoringStatus == .unavailable {
            entries.append(.text("Monitoring unavailable", .secondary))
        }
        for warning in usage.warnings.prefix(2) {
            entries.append(.text(warning, .secondary))
        }
        guard !usage.rows.isEmpty else { return }
        entries.append(.divider)
        for row in usage.rows.prefix(usage.rows.count) {
            entries.append(.text(Self.rowSummary(row, currencyCode: usage.currencyCode), .primary))
            if let detail = Self.rowDetail(row) {
                entries.append(.text(detail, .secondary))
            }
        }
    }

    private static func rowSummary(_ row: GoogleCloudCostRow, currencyCode: String) -> String {
        let cost = UsageFormatter.currencyString(row.netCost, currencyCode: currencyCode)
        let percent = String(format: "%.0f%%", row.percentOfTotal)
        if let requestCount = row.requestCount {
            return "\(row.title): \(cost) · \(percent) · \(UsageFormatter.tokenCountString(requestCount)) requests"
        }
        return "\(row.title): \(cost) · \(percent)"
    }

    private static func rowDetail(_ row: GoogleCloudCostRow) -> String? {
        var parts: [String] = []
        if let errors = row.errorRequestCount, errors > 0 {
            parts.append("\(UsageFormatter.tokenCountString(errors)) errors")
        }
        if let method = row.monitoringBreakdown?.methods.first?.method {
            parts.append("Top method: \(method)")
        }
        if let credential = row.monitoringBreakdown?.credentials.first?.displayID {
            parts.append("Top credential: \(credential)")
        }
        if let projectID = row.projectID {
            parts.append(projectID)
        }
        if let serviceID = row.serviceID, row.kind != .special {
            parts.append(serviceID)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor
    private static func serviceAccountJSONPickerAction(
        context: ProviderSettingsContext)
        -> ProviderSettingsActionDescriptor
    {
        ProviderSettingsActionDescriptor(
            id: "googlecloud-choose-service-account-json",
            title: "Choose JSON...",
            style: .bordered,
            isVisible: nil,
            perform: {
                let panel = NSOpenPanel()
                panel.title = "Choose Google Cloud service account JSON"
                panel.prompt = "Choose"
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.resolvesAliases = true
                if #available(macOS 11.0, *) {
                    panel.allowedContentTypes = [.json]
                } else {
                    panel.allowedFileTypes = ["json"]
                }
                let existingPath = context.settings.googleCloudServiceAccountJSONPath
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !existingPath.isEmpty {
                    panel.directoryURL = URL(fileURLWithPath: existingPath)
                        .deletingLastPathComponent()
                }
                guard panel.runModal() == .OK,
                      let url = panel.url
                else {
                    return
                }
                context.settings.googleCloudServiceAccountJSONPath = url.path
            })
    }

    @MainActor
    private static func consoleAction(id: String, title: String, url: String) -> ProviderSettingsActionDescriptor {
        ProviderSettingsActionDescriptor(
            id: id,
            title: title,
            style: .link,
            isVisible: nil,
            perform: {
                if let url = URL(string: url) {
                    NSWorkspace.shared.open(url)
                }
            })
    }
}
