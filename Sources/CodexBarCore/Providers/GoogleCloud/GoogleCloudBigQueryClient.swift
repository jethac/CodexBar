import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GoogleCloudBillingExportTable: Sendable, Equatable {
    public let projectID: String
    public let datasetID: String
    public let tableID: String
    public let kind: GoogleCloudBillingExportKind

    public init(projectID: String, datasetID: String, tableID: String, kind: GoogleCloudBillingExportKind) {
        self.projectID = projectID
        self.datasetID = datasetID
        self.tableID = tableID
        self.kind = kind
    }

    public var sqlName: String {
        "`\(self.projectID).\(self.datasetID).\(self.tableID)`"
    }
}

public struct GoogleCloudBillingQueryResult: Sendable {
    public let period: GoogleCloudBillingPeriod
    public let currencyCode: String
    public let grossCost: Double
    public let credits: Double
    public let netCost: Double
    public let rows: [GoogleCloudCostRow]
    public let exportTable: GoogleCloudBillingExportTable
    public let latestUsageDate: String?

    public init(
        period: GoogleCloudBillingPeriod,
        currencyCode: String,
        grossCost: Double,
        credits: Double,
        netCost: Double,
        rows: [GoogleCloudCostRow],
        exportTable: GoogleCloudBillingExportTable,
        latestUsageDate: String? = nil)
    {
        self.period = period
        self.currencyCode = currencyCode
        self.grossCost = grossCost
        self.credits = credits
        self.netCost = netCost
        self.rows = rows
        self.exportTable = exportTable
        self.latestUsageDate = latestUsageDate
    }
}

public final class GoogleCloudBigQueryClient: @unchecked Sendable {
    public static let readonlyScope = "https://www.googleapis.com/auth/bigquery.readonly"

    private let tokenProvider: GoogleCloudServiceAccountTokenProvider
    private let transport: any ProviderHTTPTransport
    private let baseURL: URL

    public init(
        tokenProvider: GoogleCloudServiceAccountTokenProvider,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        baseURL: URL = URL(string: "https://bigquery.googleapis.com")!)
    {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.baseURL = baseURL
    }

    public func fetchBilling(
        settings: GoogleCloudSettings,
        period: GoogleCloudBillingPeriod) async throws -> GoogleCloudBillingQueryResult
    {
        let table = try await self.discoverTable(settings: settings)
        let totalRows = try await self.queryRows(
            projectID: settings.billingProjectID,
            sql: Self.totalSQL(table: table),
            parameters: Self.periodParameters(period))
        let total = try Self.singleTotal(from: totalRows)
        let latestRows = try await self.queryRows(
            projectID: settings.billingProjectID,
            sql: Self.latestUsageSQL(table: table),
            parameters: Self.periodParameters(period))
        let latestUsageDate = Self.singleString(from: latestRows)
        let topLimit = settings.topRowCount

        async let geminiRows = self.queryRows(
            projectID: settings.billingProjectID,
            sql: Self.geminiSQL(table: table),
            parameters: Self.periodParameters(period))
        async let serviceRows = self.queryRows(
            projectID: settings.billingProjectID,
            sql: Self.topServicesSQL(table: table),
            parameters: Self.periodParameters(period) + [.int64("limit", topLimit)])
        async let projectRows = self.queryRows(
            projectID: settings.billingProjectID,
            sql: Self.topProjectsSQL(table: table),
            parameters: Self.periodParameters(period) + [.int64("limit", topLimit)])
        let labelRowsTask: [BigQueryRow] = if let label = settings.costLabelKey {
            try await self.queryRows(
                projectID: settings.billingProjectID,
                sql: Self.topLabelsSQL(table: table),
                parameters: Self.periodParameters(period) + [.string("label_key", label), .int64("limit", topLimit)])
        } else {
            []
        }

        let resolvedGeminiRows = try await geminiRows
        let resolvedServiceRows = try await serviceRows
        let resolvedProjectRows = try await projectRows
        let rows = try Self.makeRows(
            geminiRows: resolvedGeminiRows,
            serviceRows: resolvedServiceRows,
            projectRows: resolvedProjectRows,
            labelRows: labelRowsTask,
            totalNetCost: total.netCost,
            limit: topLimit)

        return GoogleCloudBillingQueryResult(
            period: period,
            currencyCode: total.currency,
            grossCost: total.grossCost,
            credits: total.credits,
            netCost: total.netCost,
            rows: rows,
            exportTable: table,
            latestUsageDate: latestUsageDate)
    }

    public func discoverTable(settings: GoogleCloudSettings) async throws -> GoogleCloudBillingExportTable {
        try Self.validateIdentifier(settings.billingProjectID, name: "billing project id")
        try Self.validateIdentifier(settings.billingDatasetID, name: "billing dataset id")
        if let override = settings.billingTableID {
            try Self.validateIdentifier(override, name: "billing table id")
            return GoogleCloudBillingExportTable(
                projectID: settings.billingProjectID,
                datasetID: settings.billingDatasetID,
                tableID: override,
                kind: Self.kind(for: override))
        }

        let token = try await self.tokenProvider.accessToken(scopes: [Self.readonlyScope])
        let url = self.baseURL
            .appendingPathComponent("bigquery")
            .appendingPathComponent("v2")
            .appendingPathComponent("projects")
            .appendingPathComponent(settings.billingProjectID)
            .appendingPathComponent("datasets")
            .appendingPathComponent(settings.billingDatasetID)
            .appendingPathComponent("tables")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "maxResults", value: "1000")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let response = try await self.transport.response(for: request, retryPolicy: .transientIdempotent)
        guard response.statusCode == 200 else {
            if response.statusCode == 404 {
                throw GoogleCloudUsageError.datasetNotFound
            }
            throw GoogleCloudUsageError.bigQueryError("table listing HTTP \(response.statusCode)")
        }
        let listing = try JSONDecoder().decode(TableListResponse.self, from: response.data)
        let tableIDs = listing.tables?.compactMap(\.tableReference.tableID) ?? []
        guard let tableID = Self.preferredTable(from: tableIDs) else {
            throw GoogleCloudUsageError.billingExportTableNotFound
        }
        return GoogleCloudBillingExportTable(
            projectID: settings.billingProjectID,
            datasetID: settings.billingDatasetID,
            tableID: tableID,
            kind: Self.kind(for: tableID))
    }

    private func queryRows(
        projectID: String,
        sql: String,
        parameters: [BigQueryParameter]) async throws -> [BigQueryRow]
    {
        let token = try await self.tokenProvider.accessToken(scopes: [Self.readonlyScope])
        var request = URLRequest(url: self.baseURL
            .appendingPathComponent("bigquery")
            .appendingPathComponent("v2")
            .appendingPathComponent("projects")
            .appendingPathComponent(projectID)
            .appendingPathComponent("queries"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": sql,
            "useLegacySql": false,
            "parameterMode": "NAMED",
            "queryParameters": parameters.map(\.json),
        ])

        let response = try await self.transport.response(for: request, retryPolicy: .transientIdempotent)
        guard response.statusCode == 200 else {
            throw GoogleCloudUsageError.bigQueryError("query HTTP \(response.statusCode)")
        }
        let decoded = try JSONDecoder().decode(QueryResponse.self, from: response.data)
        guard decoded.jobComplete != false else {
            throw GoogleCloudUsageError.bigQueryError("query did not complete synchronously")
        }
        return decoded.rows ?? []
    }

    private static func preferredTable(from tableIDs: [String]) -> String? {
        tableIDs.sorted().first { $0.hasPrefix("gcp_billing_export_resource_v1_") }
            ?? tableIDs.sorted().first { $0.hasPrefix("gcp_billing_export_v1_") }
    }

    private static func kind(for tableID: String) -> GoogleCloudBillingExportKind {
        if tableID.hasPrefix("gcp_billing_export_resource_v1_") {
            return .detailed
        }
        if tableID.lowercased().contains("focus") {
            return .focus
        }
        return .standard
    }

    static func validateIdentifier(_ raw: String, name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !raw.isEmpty,
              raw.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw GoogleCloudUsageError.invalidIdentifier(name)
        }
    }

    private static func periodParameters(_ period: GoogleCloudBillingPeriod) -> [BigQueryParameter] {
        [.date("start_date", period.startDate), .date("end_date", period.endDate)]
    }

    private static func singleTotal(from rows: [BigQueryRow]) throws -> BillingTotal {
        let totals = rows.compactMap(BillingTotal.init(row:))
        guard !totals.isEmpty else { throw GoogleCloudUsageError.emptyBillingExport }
        let currencies = Set(totals.map(\.currency))
        guard currencies.count == 1 else { throw GoogleCloudUsageError.multipleCurrencies(currencies.sorted()) }
        return totals.reduce(BillingTotal(currency: totals[0].currency, grossCost: 0, credits: 0, netCost: 0)) {
            BillingTotal(
                currency: $0.currency,
                grossCost: $0.grossCost + $1.grossCost,
                credits: $0.credits + $1.credits,
                netCost: $0.netCost + $1.netCost)
        }
    }

    static func singleString(from rows: [BigQueryRow]) -> String? {
        rows.first?.string(0)
    }

    private static func makeRows(
        geminiRows: [BigQueryRow],
        serviceRows: [BigQueryRow],
        projectRows: [BigQueryRow],
        labelRows: [BigQueryRow],
        totalNetCost: Double,
        limit: Int) throws -> [GoogleCloudCostRow]
    {
        var rows: [GoogleCloudCostRow] = []
        let geminiTotal = try? Self.singleTotal(from: geminiRows)
        if let geminiTotal, geminiTotal.netCost != 0 {
            rows.append(GoogleCloudCostRow(
                id: GoogleCloudCostRow.geminiAPIID,
                title: "Gemini API",
                kind: .special,
                serviceID: "generativelanguage.googleapis.com",
                serviceDescription: "Generative Language API",
                grossCost: geminiTotal.grossCost,
                credits: geminiTotal.credits,
                netCost: geminiTotal.netCost,
                percentOfTotal: Self.percent(geminiTotal.netCost, of: totalNetCost)))
        }

        let serviceRows = serviceRows.compactMap { BillingGroupedRow(row: $0, kind: .service) }
            .filter { row in
                row.netCost != 0 &&
                    row.serviceID != "generativelanguage.googleapis.com" &&
                    row.title.localizedCaseInsensitiveCompare("Gemini API") != .orderedSame
            }
            .map { $0.costRow(totalNetCost: totalNetCost) }
        rows.append(contentsOf: serviceRows)

        rows.append(contentsOf: projectRows.compactMap { BillingGroupedRow(row: $0, kind: .project) }
            .filter { $0.netCost != 0 }
            .map { $0.costRow(totalNetCost: totalNetCost) })
        rows.append(contentsOf: labelRows.compactMap { BillingGroupedRow(row: $0, kind: .label) }
            .filter { $0.netCost != 0 }
            .map { $0.costRow(totalNetCost: totalNetCost) })

        return rows
            .sorted {
                if $0.netCost == $1.netCost { return $0.title < $1.title }
                return $0.netCost > $1.netCost
            }
            .prefix(limit)
            .map(\.self)
    }

    static func percent(_ value: Double, of total: Double) -> Double {
        guard total != 0 else { return 0 }
        return max(0, min(100, (value / total) * 100))
    }

    private static func totalSQL(table: GoogleCloudBillingExportTable) -> String {
        """
        SELECT
          currency,
          SUM(cost) AS gross_cost,
          SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS credits,
          SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net_cost
        FROM \(table.sqlName)
        WHERE DATE(usage_start_time) >= @start_date
          AND DATE(usage_start_time) < @end_date
        GROUP BY currency
        """
    }

    private static func latestUsageSQL(table: GoogleCloudBillingExportTable) -> String {
        """
        SELECT CAST(MAX(DATE(usage_start_time)) AS STRING) AS latest_usage_date
        FROM \(table.sqlName)
        WHERE DATE(usage_start_time) >= @start_date
          AND DATE(usage_start_time) < @end_date
        """
    }

    private static func topServicesSQL(table: GoogleCloudBillingExportTable) -> String {
        """
        SELECT
          service.id AS service_id,
          service.description AS service_description,
          currency,
          SUM(cost) AS gross_cost,
          SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS credits,
          SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net_cost,
          SUM(usage.amount) AS usage_amount,
          ANY_VALUE(usage.unit) AS usage_unit
        FROM \(table.sqlName)
        WHERE DATE(usage_start_time) >= @start_date
          AND DATE(usage_start_time) < @end_date
        GROUP BY service_id, service_description, currency
        ORDER BY net_cost DESC
        LIMIT @limit
        """
    }

    private static func geminiSQL(table: GoogleCloudBillingExportTable) -> String {
        """
        SELECT
          currency,
          SUM(cost) AS gross_cost,
          SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS credits,
          SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net_cost
        FROM \(table.sqlName)
        WHERE DATE(usage_start_time) >= @start_date
          AND DATE(usage_start_time) < @end_date
          AND (
            service.id = 'generativelanguage.googleapis.com'
            OR service.description LIKE '%Generative Language%'
            OR service.description LIKE '%Gemini%'
            OR sku.description LIKE '%Gemini%'
            OR sku.description LIKE '%Generative Language%'
          )
        GROUP BY currency
        """
    }

    private static func topProjectsSQL(table: GoogleCloudBillingExportTable) -> String {
        """
        SELECT
          project.id AS project_id,
          project.name AS project_name,
          currency,
          SUM(cost) AS gross_cost,
          SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS credits,
          SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net_cost
        FROM \(table.sqlName)
        WHERE DATE(usage_start_time) >= @start_date
          AND DATE(usage_start_time) < @end_date
        GROUP BY project_id, project_name, currency
        ORDER BY net_cost DESC
        LIMIT @limit
        """
    }

    private static func topLabelsSQL(table: GoogleCloudBillingExportTable) -> String {
        """
        SELECT
          label.key AS label_key,
          label.value AS label_value,
          currency,
          SUM(cost) AS gross_cost,
          SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS credits,
          SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net_cost
        FROM \(table.sqlName), UNNEST(labels) AS label
        WHERE DATE(usage_start_time) >= @start_date
          AND DATE(usage_start_time) < @end_date
          AND label.key = @label_key
        GROUP BY label_key, label_value, currency
        ORDER BY net_cost DESC
        LIMIT @limit
        """
    }
}

struct BigQueryParameter: Sendable {
    let name: String
    let type: String
    let value: String

    static func string(_ name: String, _ value: String) -> Self {
        Self(name: name, type: "STRING", value: value)
    }

    static func date(_ name: String, _ value: String) -> Self {
        Self(name: name, type: "DATE", value: value)
    }

    static func int64(_ name: String, _ value: Int) -> Self {
        Self(name: name, type: "INT64", value: String(value))
    }

    var json: [String: Any] {
        [
            "name": self.name,
            "parameterType": ["type": self.type],
            "parameterValue": ["value": self.value],
        ]
    }
}

struct BigQueryRow: Decodable, Sendable {
    let f: [Field]

    struct Field: Decodable, Sendable {
        let v: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let string = try? container.decodeIfPresent(String.self, forKey: .v) {
                self.v = string
                return
            }
            if let int = try? container.decodeIfPresent(Int.self, forKey: .v) {
                self.v = String(int)
                return
            }
            if let double = try? container.decodeIfPresent(Double.self, forKey: .v) {
                self.v = String(double)
                return
            }
            self.v = nil
        }

        private enum CodingKeys: String, CodingKey {
            case v
        }
    }

    func string(_ index: Int) -> String? {
        guard self.f.indices.contains(index) else { return nil }
        return GoogleCloudSettingsReader.cleaned(self.f[index].v)
    }

    func double(_ index: Int) -> Double {
        self.string(index).flatMap(Double.init) ?? 0
    }
}

private struct BillingTotal: Sendable {
    let currency: String
    let grossCost: Double
    let credits: Double
    let netCost: Double

    init(currency: String, grossCost: Double, credits: Double, netCost: Double) {
        self.currency = currency
        self.grossCost = grossCost
        self.credits = credits
        self.netCost = netCost
    }

    init?(row: BigQueryRow) {
        guard let currency = row.string(0) else { return nil }
        self.currency = currency
        self.grossCost = row.double(1)
        self.credits = row.double(2)
        self.netCost = row.double(3)
    }
}

private struct BillingGroupedRow: Sendable {
    let kind: GoogleCloudCostRowKind
    let id: String
    let title: String
    let serviceID: String?
    let serviceDescription: String?
    let projectID: String?
    let projectName: String?
    let labelKey: String?
    let labelValue: String?
    let grossCost: Double
    let credits: Double
    let netCost: Double
    let usageAmount: Double?
    let usageUnit: String?

    init?(row: BigQueryRow, kind: GoogleCloudCostRowKind) {
        self.kind = kind
        switch kind {
        case .service:
            let serviceID = row.string(0)
            let serviceDescription = row.string(1)
            self.id = "service:\(serviceID ?? serviceDescription ?? "unknown")"
            self.title = serviceDescription ?? serviceID ?? "Unknown service"
            self.serviceID = serviceID
            self.serviceDescription = serviceDescription
            self.projectID = nil
            self.projectName = nil
            self.labelKey = nil
            self.labelValue = nil
            self.grossCost = row.double(3)
            self.credits = row.double(4)
            self.netCost = row.double(5)
            self.usageAmount = row.double(6) == 0 ? nil : row.double(6)
            self.usageUnit = row.string(7)
        case .project:
            let projectID = row.string(0)
            let projectName = row.string(1)
            self.id = "project:\(projectID ?? projectName ?? "unknown")"
            self.title = projectName ?? projectID ?? "Unknown project"
            self.serviceID = nil
            self.serviceDescription = nil
            self.projectID = projectID
            self.projectName = projectName
            self.labelKey = nil
            self.labelValue = nil
            self.grossCost = row.double(3)
            self.credits = row.double(4)
            self.netCost = row.double(5)
            self.usageAmount = nil
            self.usageUnit = nil
        case .label:
            let key = row.string(0)
            let value = row.string(1)
            self.id = "label:\(key ?? "label"):\(value ?? "unknown")"
            self.title = value ?? "Unlabeled"
            self.serviceID = nil
            self.serviceDescription = nil
            self.projectID = nil
            self.projectName = nil
            self.labelKey = key
            self.labelValue = value
            self.grossCost = row.double(3)
            self.credits = row.double(4)
            self.netCost = row.double(5)
            self.usageAmount = nil
            self.usageUnit = nil
        case .sku, .special:
            return nil
        }
    }

    func costRow(totalNetCost: Double) -> GoogleCloudCostRow {
        GoogleCloudCostRow(
            id: self.id,
            title: self.title,
            kind: self.kind,
            serviceID: self.serviceID,
            serviceDescription: self.serviceDescription,
            projectID: self.projectID,
            projectName: self.projectName,
            labelKey: self.labelKey,
            labelValue: self.labelValue,
            grossCost: self.grossCost,
            credits: self.credits,
            netCost: self.netCost,
            usageAmount: self.usageAmount,
            usageUnit: self.usageUnit,
            percentOfTotal: GoogleCloudBigQueryClient.percent(self.netCost, of: totalNetCost))
    }
}

private struct TableListResponse: Decodable {
    let tables: [Table]?

    struct Table: Decodable {
        let tableReference: Reference
    }

    struct Reference: Decodable {
        let tableID: String

        private enum CodingKeys: String, CodingKey {
            case tableID = "tableId"
        }
    }
}

private struct QueryResponse: Decodable {
    let jobComplete: Bool?
    let rows: [BigQueryRow]?
}
