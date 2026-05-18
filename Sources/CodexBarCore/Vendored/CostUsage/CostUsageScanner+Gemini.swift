import Foundation

extension CostUsageScanner {
    // MARK: - Gemini CLI sessions

    static func loadGeminiDaily(range: CostUsageDayRange, options: Options) -> CostUsageDailyReport {
        let root = options.geminiConfigRoot ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".gemini", isDirectory: true)
        let files = self.geminiSessionFiles(root: root)
        guard !files.isEmpty else { return CostUsageDailyReport(data: [], summary: nil) }

        var days: [String: GeminiDailyTotals] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = object["messages"] as? [[String: Any]]
            else { continue }

            for message in messages {
                guard !self.isGeminiVertexMessage(message),
                      let tokens = message["tokens"] as? [String: Any],
                      let dayKey = self.geminiDayKey(message: message),
                      CostUsageDayRange.isInRange(dayKey: dayKey, since: range.sinceKey, until: range.untilKey)
                else { continue }

                var totals = days[dayKey] ?? GeminiDailyTotals()
                totals.input += self.intValue(tokens["input"])
                totals.cached += self.intValue(tokens["cached"])
                totals.output += self.intValue(tokens["output"])
                let total = self.intValue(tokens["total"])
                totals.total += total > 0 ? total : self.intValue(tokens["input"]) + self
                    .intValue(tokens["cached"]) + self.intValue(tokens["output"])
                if let model = message["model"] as? String, !model.isEmpty {
                    totals.models.insert(model)
                }
                days[dayKey] = totals
            }
        }

        let entries = days.keys.sorted().compactMap { dayKey -> CostUsageDailyReport.Entry? in
            guard let totals = days[dayKey], !totals.isEmpty else { return nil }
            return CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: totals.input,
                outputTokens: totals.output,
                cacheReadTokens: totals.cached == 0 ? nil : totals.cached,
                totalTokens: totals.total,
                costUSD: nil,
                modelsUsed: totals.models.sorted(),
                modelBreakdowns: totals.modelBreakdowns)
        }
        guard !entries.isEmpty else { return CostUsageDailyReport(data: [], summary: nil) }
        return CostUsageDailyReport(data: entries, summary: nil)
    }

    private struct GeminiDailyTotals {
        var input = 0
        var cached = 0
        var output = 0
        var total = 0
        var models: Set<String> = []

        var isEmpty: Bool {
            self.total == 0 && self.input == 0 && self.cached == 0 && self.output == 0
        }

        var modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]? {
            let sorted = self.models.sorted()
            return sorted.isEmpty ? nil : sorted.map {
                CostUsageDailyReport.ModelBreakdown(modelName: $0, costUSD: nil, totalTokens: nil)
            }
        }
    }

    private static func geminiSessionFiles(root: URL) -> [URL] {
        let chatsRoot = root.appendingPathComponent("tmp", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: chatsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.pathExtension == "json",
                  url.lastPathComponent.hasPrefix("session-")
            else { return nil }
            return url
        }
    }

    private static func geminiDayKey(message: [String: Any]) -> String? {
        guard let timestamp = message["timestamp"] as? String,
              let date = self.dateFromTimestamp(timestamp)
        else { return nil }
        return CostUsageDayRange.dayKey(from: date)
    }

    private static func isGeminiVertexMessage(_ message: [String: Any]) -> Bool {
        for key in ["provider", "authType", "platform"] {
            if let value = message[key] as? String, value.lowercased().contains("vertex") { return true }
        }
        return false
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }
}
