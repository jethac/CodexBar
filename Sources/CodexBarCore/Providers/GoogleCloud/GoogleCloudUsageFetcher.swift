import Foundation

public enum GoogleCloudUsageFetcher {
    public static func fetchUsage(
        settings: GoogleCloudSettings,
        serviceAccount: GoogleCloudServiceAccount,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> GoogleCloudUsageSnapshot
    {
        let tokenProvider = GoogleCloudServiceAccountTokenProvider(
            account: serviceAccount,
            transport: transport,
            now: { now })
        let period = Self.currentMonthPeriod(now: now)
        let billingClient = GoogleCloudBigQueryClient(tokenProvider: tokenProvider, transport: transport)
        let billing = try await billingClient.fetchBilling(settings: settings, period: period)

        var monitoring: GoogleCloudMonitoringSnapshot?
        var monitoringStatus: GoogleCloudMonitoringStatus = settings.monitoringEnabled ? .unavailable : .disabled
        var warnings: [String] = []

        if settings.monitoringEnabled {
            do {
                let monitoringClient = GoogleCloudMonitoringClient(tokenProvider: tokenProvider, transport: transport)
                monitoring = try await monitoringClient.fetchGeminiAPIRequests(
                    projectID: settings.monitoringProjectID,
                    period: period,
                    updatedAt: now)
                monitoringStatus = .available
            } catch {
                warnings.append("Cloud Monitoring unavailable: \(Self.safeWarning(error))")
                monitoringStatus = .unavailable
            }
        }

        let rows = Self.attachMonitoring(
            monitoring?.geminiAPI,
            to: billing.rows)

        return GoogleCloudUsageSnapshot(
            period: period,
            currencyCode: billing.currencyCode,
            grossCost: billing.grossCost,
            credits: billing.credits,
            netCost: billing.netCost,
            rows: rows,
            monitoring: monitoring,
            monitoringStatus: monitoringStatus,
            warnings: warnings,
            exportTable: billing.exportTable.tableID,
            exportKind: billing.exportTable.kind,
            billingLatestUsageDate: billing.latestUsageDate,
            updatedAt: now)
    }

    static func attachMonitoring(
        _ service: GoogleCloudMonitoredService?,
        to rows: [GoogleCloudCostRow]) -> [GoogleCloudCostRow]
    {
        guard let service else { return rows }
        var foundGemini = false
        let attached = rows.map { row in
            guard row.id == GoogleCloudCostRow.geminiAPIID else { return row }
            foundGemini = true
            return GoogleCloudCostRow(
                id: row.id,
                title: row.title,
                kind: row.kind,
                serviceID: row.serviceID,
                serviceDescription: row.serviceDescription,
                projectID: row.projectID,
                projectName: row.projectName,
                skuDescription: row.skuDescription,
                labelKey: row.labelKey,
                labelValue: row.labelValue,
                grossCost: row.grossCost,
                credits: row.credits,
                netCost: row.netCost,
                usageAmount: row.usageAmount,
                usageUnit: row.usageUnit,
                requestCount: service.requestCount,
                successfulRequestCount: service.successfulRequestCount,
                errorRequestCount: service.errorRequestCount,
                monitoringBreakdown: service.breakdown,
                percentOfTotal: row.percentOfTotal)
        }
        if foundGemini || service.requestCount <= 0 {
            return attached
        }
        return ([
            GoogleCloudCostRow(
                id: GoogleCloudCostRow.geminiAPIID,
                title: "Gemini API",
                kind: .special,
                serviceID: "generativelanguage.googleapis.com",
                serviceDescription: "Generative Language API",
                grossCost: 0,
                credits: 0,
                netCost: 0,
                requestCount: service.requestCount,
                successfulRequestCount: service.successfulRequestCount,
                errorRequestCount: service.errorRequestCount,
                monitoringBreakdown: service.breakdown,
                percentOfTotal: 0),
        ] + attached)
    }

    public static func currentMonthPeriod(now: Date = Date()) -> GoogleCloudBillingPeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: components) ?? now
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        let formatter = GoogleCloudBillingPeriod.makeDateFormatter()
        return GoogleCloudBillingPeriod(
            startDate: formatter.string(from: start),
            endDate: formatter.string(from: end),
            label: "This month")
    }

    private static func safeWarning(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription
        {
            return description
        }
        return error.localizedDescription
    }
}
