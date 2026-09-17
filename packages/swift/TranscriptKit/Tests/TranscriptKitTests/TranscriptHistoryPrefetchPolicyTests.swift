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
  @Test("Newer pages require forward intent and do not reload after anchor compensation")
  func newerPaginationFollowsUserIntent() {
    var policy = TranscriptHistoryPrefetchPolicy()
    var requests: [Bool] = []
    func attempt(_ key: String = "last", distance: Double = 0, follows: Bool = false) -> Bool {
      policy.requestNewerIfNeeded(
        newestKey: key, distanceFromBoundary: distance, threshold: 600,
        followsLatest: follows
      ) { latest in
        requests.append(latest); return true
      }
    }
    #expect(!attempt())
    policy.observeUserScroll(delta: 100)
    #expect(!attempt(distance: 1000))
    #expect(attempt())
    #expect(!attempt())
    #expect(attempt("next"))
    policy.observeUserScroll(delta: -100)
    #expect(!attempt("another"))
    #expect(attempt("another", distance: 10000, follows: true))
    #expect(requests == [false, false, true])
  }

  @Test("Rejected newer demand can retry; an accepted failure rearms after leaving the boundary")
  func newerPaginationRetry() {
    var policy = TranscriptHistoryPrefetchPolicy()
    policy.observeUserScroll(delta: 1)
    for accepted in [false, true, false] {
      let result = policy.requestNewerIfNeeded(
        newestKey: "last", distanceFromBoundary: 0, threshold: 600, followsLatest: false
      ) { _ in accepted }
      #expect(result == accepted)
    }
    #expect(
      !policy.requestNewerIfNeeded(
        newestKey: "last", distanceFromBoundary: 751, threshold: 600, followsLatest: false
      ) { _ in
        Issue.record("Requested outside prefetch zone"); return true
      })
    #expect(
      policy.requestNewerIfNeeded(
        newestKey: "last", distanceFromBoundary: 0, threshold: 600, followsLatest: false
      ) { _ in true })
  }

}
