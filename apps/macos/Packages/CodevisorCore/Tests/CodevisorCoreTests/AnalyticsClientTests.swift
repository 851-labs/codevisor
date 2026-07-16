import Testing
@testable import CodevisorCore

@MainActor
@Suite("Analytics privacy primitives")
struct AnalyticsClientTests {
    @Test("Event names are a closed manual allowlist")
    func eventAllowlist() {
        #expect(Set(AnalyticsEventName.allCases.map(\.rawValue)) == [
            "app opened",
            "chat created",
            "message sent",
            "model selected",
            "harness selected",
            "turn completed",
            "turn failed"
        ])
    }

    @Test("Token usage is reduced to coarse buckets")
    func tokenBuckets() {
        #expect(AnalyticsClient.tokenBucket(nil) == nil)
        #expect(AnalyticsClient.tokenBucket(0) == "0")
        #expect(AnalyticsClient.tokenBucket(999) == "1-999")
        #expect(AnalyticsClient.tokenBucket(1_000) == "1k-9.9k")
        #expect(AnalyticsClient.tokenBucket(10_000) == "10k-99.9k")
        #expect(AnalyticsClient.tokenBucket(100_000) == "100k+")
    }
}
