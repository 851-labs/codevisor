import Testing
@testable import TranscriptKit

@Suite("Transcript history prefetch policy")
struct TranscriptHistoryPrefetchPolicyTests {
    @Test("A rejected request does not consume the oldest row")
    func rejectedRequestCanRetry() {
        var policy = TranscriptHistoryPrefetchPolicy()
        var attempts = 0

        let rejected = policy.requestIfNeeded(
            oldestKey: "oldest",
            distanceFromTop: 0,
            threshold: 600
        ) {
            attempts += 1
            return false
        }
        let accepted = policy.requestIfNeeded(
            oldestKey: "oldest",
            distanceFromTop: 0,
            threshold: 600
        ) {
            attempts += 1
            return true
        }

        #expect(!rejected)
        #expect(accepted)
        #expect(attempts == 2)
    }

    @Test("An accepted request is deduplicated until the oldest row changes")
    func acceptedRequestIsDeduplicated() {
        var policy = TranscriptHistoryPrefetchPolicy()
        var attempts = 0

        for key in ["first", "first", "second"] {
            policy.requestIfNeeded(
                oldestKey: key,
                distanceFromTop: 0,
                threshold: 600
            ) {
                attempts += 1
                return true
            }
        }

        #expect(attempts == 2)
    }

    @Test("Leaving the prefetch zone rearms the same oldest row")
    func leavingPrefetchZoneRearmsRequest() {
        var policy = TranscriptHistoryPrefetchPolicy()
        var attempts = 0
        let request = {
            attempts += 1
            return true
        }

        policy.requestIfNeeded(
            oldestKey: "oldest",
            distanceFromTop: 0,
            threshold: 600,
            request: request
        )
        policy.requestIfNeeded(
            oldestKey: "oldest",
            distanceFromTop: 751,
            threshold: 600,
            request: request
        )
        policy.requestIfNeeded(
            oldestKey: "oldest",
            distanceFromTop: 0,
            threshold: 600,
            request: request
        )

        #expect(attempts == 2)
    }
}
