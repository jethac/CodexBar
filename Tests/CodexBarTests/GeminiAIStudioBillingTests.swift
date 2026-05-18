import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct GeminiAIStudioBillingTests {
    @Test
    func `resolves API key to project and billing account`() async throws {
        let fetcher = GeminiAIStudioBillingFetcher(
            accessTokenProvider: { "oauth-token" },
            dataLoader: { request in
                guard let url = request.url?.absoluteString else {
                    Issue.record("Missing request URL")
                    throw URLError(.badURL)
                }
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token")

                if url.contains("apikeys.googleapis.com") {
                    let body = """
                    {
                      "parent": "projects/701243853572/locations/global",
                      "name": "projects/701243853572/locations/global/keys/key-id"
                    }
                    """
                    return (Data(body.utf8), HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil)!)
                }

                #expect(url == "https://cloudbilling.googleapis.com/v1/projects/701243853572/billingInfo")
                let body = """
                {
                  "name": "projects/gen-lang-client-0530062602/billingInfo",
                  "projectId": "gen-lang-client-0530062602",
                  "billingAccountName": "billingAccounts/0133F1-B4A588-73A9E8",
                  "billingEnabled": true
                }
                """
                return (Data(body.utf8), HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!)
            })

        let context = try await fetcher.resolveContext(apiKey: "AIza-test")

        #expect(context.projectNumber == "701243853572")
        #expect(context.projectID == "gen-lang-client-0530062602")
        #expect(context.billingAccountID == "0133F1-B4A588-73A9E8")
        #expect(context.billingEnabled)
        #expect(context.billingURL?
            .absoluteString == "https://aistudio.google.com/billing?billing=0133F1-B4A588-73A9E8")
        #expect(context.usageURL
            .absoluteString == "https://aistudio.google.com/usage?project=gen-lang-client-0530062602")
    }

    @Test
    func `reports free project when billing is disabled`() async throws {
        let fetcher = GeminiAIStudioBillingFetcher(
            accessTokenProvider: { "oauth-token" },
            dataLoader: { request in
                guard let url = request.url?.absoluteString else {
                    Issue.record("Missing request URL")
                    throw URLError(.badURL)
                }
                if url.contains("apikeys.googleapis.com") {
                    let body = """
                    { "parent": "projects/722349853272/locations/global" }
                    """
                    return (Data(body.utf8), HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil)!)
                }
                let body = """
                {
                  "name": "projects/gen-lang-client-0903747773/billingInfo",
                  "projectId": "gen-lang-client-0903747773",
                  "billingAccountName": "",
                  "billingEnabled": false
                }
                """
                return (Data(body.utf8), HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!)
            })

        let context = try await fetcher.resolveContext(apiKey: "AIza-free")

        #expect(context.projectNumber == "722349853272")
        #expect(context.projectID == "gen-lang-client-0903747773")
        #expect(context.billingAccountID == nil)
        #expect(context.billingEnabled == false)
        #expect(context.billingURL == nil)
        #expect(context.usageURL
            .absoluteString == "https://aistudio.google.com/usage?project=gen-lang-client-0903747773")
    }

    @Test
    func `parses AI Studio prepay billing page text`() {
        let snapshot = GeminiAIStudioBillingParser.parseBillingPageText("""
        Available credits
        $42.17
        Billing plan
        Prepay
        Spend this month
        $7.83
        Auto-reload enabled
        """)

        #expect(snapshot.plan == .prepay)
        #expect(snapshot.availableCredits == 42.17)
        #expect(snapshot.monthToDateSpend == 7.83)
    }

    @Test
    func `parses AI Studio postpay billing page text`() {
        let snapshot = GeminiAIStudioBillingParser.parseBillingPageText("""
        Billing plan
        Postpay
        Current balance
        $18.20
        Monthly spend cap
        $250.00
        """)

        #expect(snapshot.plan == .postpay)
        #expect(snapshot.monthToDateSpend == 18.20)
        #expect(snapshot.spendCap == 250)
    }

    @Test
    func `parses AI Studio usage page text`() {
        let snapshot = GeminiAIStudioBillingParser.parseUsagePageText("""
        API requests
        1,234
        Input tokens
        56,789
        Output tokens
        10,011
        """)

        #expect(snapshot.requestCount == 1234)
        #expect(snapshot.inputTokenCount == 56789)
        #expect(snapshot.outputTokenCount == 10011)
        #expect(snapshot.totalTokenCount == 66800)
    }
}
