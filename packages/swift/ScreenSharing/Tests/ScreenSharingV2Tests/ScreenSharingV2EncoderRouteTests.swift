import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2EncoderRouteTests {
  private static let fastAfterNs = ScreenSharingV2EncoderRoute.fastAfterNs
  private static let slowAfterNs = ScreenSharingV2EncoderRoute.slowAfterNs
  private static let fast = 20_000_000
  private static let slow = 1_000_000

  @Test func aFastLinkMovesToTheFastEncoderOnlyOnceItHeldForTheHoldWithFreshFeedback() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)

    route.observe(roundTripMs: 20, atNs: Self.fastAfterNs - 1)
    let early = route.update(atNs: Self.fastAfterNs - 1)
    let due = route.update(atNs: Self.fastAfterNs)

    #expect(!early)
    #expect(due)
    #expect(route.choice == .fast)
  }

  @Test func withoutFreshFeedbackTheSwitchWaitsForTheNextFeedback() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)
    route.observe(roundTripMs: 20, atNs: 0)

    let stale = route.update(atNs: Self.fastAfterNs + ScreenSharingV2EncoderRoute.feedbackFreshNs + 1)
    route.observe(roundTripMs: 20, atNs: Self.fastAfterNs + 2 * ScreenSharingV2EncoderRoute.feedbackFreshNs)
    let fresh = route.update(atNs: Self.fastAfterNs + 2 * ScreenSharingV2EncoderRoute.feedbackFreshNs)

    #expect(!stale)
    #expect(fresh)
  }

  @Test func aRoundTripThatShowsAQueueStartsTheHoldOver() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)
    route.observe(roundTripMs: 20, atNs: 0)

    route.observe(roundTripMs: 20 + ScreenSharingV2EncoderRoute.queuedAboveMs + 1, atNs: 1_000)

    #expect(route.switchDueNs == 1_000 + Self.fastAfterNs)
  }

  @Test func aRoundTripThatStaysHigherStopsRestartingTheHoldOnceTheOldShortestExpires() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)
    route.observe(roundTripMs: 5, atNs: 0)
    let kept = ScreenSharingV2EncoderRoute.shortestRoundTripKeptNs

    route.observe(roundTripMs: 80, atNs: kept)
    let restartedAt = route.switchDueNs
    route.observe(roundTripMs: 80, atNs: kept + 1)
    route.observe(roundTripMs: 80, atNs: kept + 2)

    #expect(restartedAt == kept + Self.fastAfterNs)
    #expect(route.switchDueNs == kept + Self.fastAfterNs)
  }

  @Test func aSlowLinkStaysOnTheSlowEncoder() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.slow, atNs: 0)
    route.observe(roundTripMs: 120, atNs: 10 * Self.fastAfterNs)

    let switched = route.update(atNs: 10 * Self.fastAfterNs)

    #expect(!switched)
    #expect(route.switchDueNs == nil)
  }

  @Test func aDropBelowTheSlowThresholdMovesBackAfterItsShorterHold() {
    var route = fastRoute()

    route.observe(bitrate: Self.slow, atNs: 2 * Self.fastAfterNs)
    let early = route.update(atNs: 2 * Self.fastAfterNs + Self.slowAfterNs - 1)
    let due = route.update(atNs: 2 * Self.fastAfterNs + Self.slowAfterNs)

    #expect(!early)
    #expect(due)
    #expect(route.choice == .slow)
  }

  @Test func aBitrateBetweenTheThresholdsKeepsEitherEncoder() {
    let between = (ScreenSharingV2EncoderRoute.slowBelowBitrate + ScreenSharingV2EncoderRoute.fastFromBitrate) / 2
    var slow = ScreenSharingV2EncoderRoute(bitrate: between, atNs: 0)
    var fast = fastRoute()
    slow.observe(roundTripMs: 20, atNs: 10 * Self.fastAfterNs)
    fast.observe(bitrate: between, atNs: 2 * Self.fastAfterNs)

    let slowSwitched = slow.update(atNs: 10 * Self.fastAfterNs)
    let fastSwitched = fast.update(atNs: 10 * Self.fastAfterNs)

    #expect(!slowSwitched)
    #expect(!fastSwitched)
    #expect((slow.choice, fast.choice) == (.slow, .fast))
  }

  @Test func aBriefDipDoesNotLeaveTheFastEncoder() {
    var route = fastRoute()

    route.observe(bitrate: Self.slow, atNs: 2 * Self.fastAfterNs)
    route.observe(bitrate: Self.fast, atNs: 2 * Self.fastAfterNs + Self.slowAfterNs / 2)
    let switched = route.update(atNs: 2 * Self.fastAfterNs + 2 * Self.slowAfterNs)

    #expect(!switched)
    #expect(route.choice == .fast)
  }

  private func fastRoute() -> ScreenSharingV2EncoderRoute {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)
    route.observe(roundTripMs: 20, atNs: Self.fastAfterNs)
    _ = route.update(atNs: Self.fastAfterNs)
    return route
  }
}
