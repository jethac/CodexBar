import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageGeminiSessionTests {
    @Test
    func `loads Gemini CLI session tokens without including Vertex AI provider data`() async throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = root
            .appendingPathComponent("tmp/project-hash/chats", isDirectory: true)
            .appendingPathComponent("session-test.json")
        try FileManager.default.createDirectory(
            at: sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let session = """
        {
          "messages": [
            {
              "timestamp": "2026-05-18T12:00:00.000Z",
              "type": "gemini",
              "model": "gemini-2.5-flash",
              "tokens": { "input": 100, "cached": 7, "output": 25, "total": 132 }
            },
            {
              "timestamp": "2026-05-18T13:00:00.000Z",
              "type": "gemini",
              "model": "gemini-2.5-pro",
              "tokens": { "input": 200, "output": 40, "total": 240 }
            },
            {
              "timestamp": "2026-05-18T14:00:00.000Z",
              "type": "gemini",
              "model": "publishers/google/models/gemini-2.5-pro",
              "provider": "vertex-ai",
              "tokens": { "input": 999, "output": 999, "total": 1998 }
            }
          ]
        }
        """
        try session.write(to: sessionURL, atomically: true, encoding: .utf8)

        let report = CostUsageScanner.loadDailyReport(
            provider: .gemini,
            since: Self.date("2026-05-18T00:00:00Z"),
            until: Self.date("2026-05-18T23:59:59Z"),
            options: CostUsageScanner.Options(geminiConfigRoot: root))

        #expect(report.data.count == 1)
        let entry = try #require(report.data.first)
        #expect(entry.date == "2026-05-18")
        #expect(entry.inputTokens == 300)
        #expect(entry.cacheReadTokens == 7)
        #expect(entry.outputTokens == 65)
        #expect(entry.totalTokens == 372)
        #expect(entry.costUSD == nil)
        #expect(entry.modelsUsed == ["gemini-2.5-flash", "gemini-2.5-pro"])

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .gemini,
            environment: ["GEMINI_CONFIG_DIR": root.path],
            now: Self.date("2026-05-18T18:00:00Z"),
            refreshPricingInBackground: false)
        #expect(snapshot.sessionTokens == 372)
        #expect(snapshot.last30DaysTokens == 372)
        #expect(snapshot.sessionCostUSD == nil)
        #expect(snapshot.last30DaysCostUSD == nil)
    }

    private func makeTemporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarGeminiSessionTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
