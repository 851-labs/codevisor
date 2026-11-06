import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2EncoderRouteTests {
  private static let fastAfterNs = ScreenSharingV2EncoderRoute.fastAfterNs
  private static let slowAfterNs = ScreenSharingV2EncoderRoute.slowAfterNs
  private static let fast = 40_000_000
  private static let slow = 1_000_000

  @Test func aFastLinkMovesToTheFastEncoderOnlyOnceItHeldForTheHoldWithFreshFeedback() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)

    route.observe(Self.feedback(20), atNs: Self.fastAfterNs - 1)
    let early = route.update(atNs: Self.fastAfterNs - 1)
    let due = route.update(atNs: Self.fastAfterNs)

    #expect(!early)
    #expect(due)
    #expect(route.choice == .fast)
  }

  @Test func withoutFreshFeedbackTheSwitchWaitsForTheNextFeedback() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)
    route.observe(Self.feedback(20), atNs: 0)

    let stale = route.update(atNs: Self.fastAfterNs + ScreenSharingV2EncoderRoute.feedbackFreshNs + 1)
    route.observe(Self.feedback(20), atNs: Self.fastAfterNs + 2 * ScreenSharingV2EncoderRoute.feedbackFreshNs)
    let fresh = route.update(atNs: Self.fastAfterNs + 2 * ScreenSharingV2EncoderRoute.feedbackFreshNs)

    #expect(!stale)
    #expect(fresh)
  }

  @Test func aRoundTripThatShowsAQueueStartsTheHoldOver() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)
    route.observe(Self.feedback(20), atNs: 0)

    route.observe(Self.feedback(20 + ScreenSharingV2EncoderRoute.queuedAboveMs + 1), atNs: 1_000)

    #expect(route.switchDueNs == 1_000 + Self.fastAfterNs)
  }

  @Test func aRoundTripThatFallsAsAQueueDrainsStartsTheHoldOver() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)
    route.observe(Self.feedback(1_800), atNs: 0)

    route.observe(Self.feedback(900), atNs: 1_000)
    route.observe(Self.feedback(880), atNs: 2_000)

    #expect(route.switchDueNs == 1_000 + Self.fastAfterNs)
  }

  @Test func aRoundTripThatStaysHigherStopsRestartingTheHoldOnceTheOldShortestExpires() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)
    route.observe(Self.feedback(5), atNs: 0)
    let kept = ScreenSharingV2EncoderRoute.shortestRoundTripKeptNs

    route.observe(Self.feedback(80), atNs: kept)
    let restartedAt = route.switchDueNs
    route.observe(Self.feedback(80), atNs: kept + 1)
    route.observe(Self.feedback(80), atNs: kept + 2)

    #expect(restartedAt == kept + Self.fastAfterNs)
    #expect(route.switchDueNs == kept + Self.fastAfterNs)
  }

  @Test func aLocalLinkThatReportsNoRoundTripStillMovesToTheFastEncoder() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)

    route.observe(Self.feedback(0), atNs: Self.fastAfterNs)
    let switched = route.update(atNs: Self.fastAfterNs)

    #expect(switched)
  }

  @Test func aRoundTripThatStaysQueuedKeepsRestartingTheHold() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)
    let step = ScreenSharingV2EncoderRoute.shortestRoundTripKeptNs / 4

    for index in 0...8 { route.observe(Self.feedback(index == 0 ? 20 : 200), atNs: Int64(index) * step / 2) }

    #expect(route.switchDueNs == 8 * step / 2 + Self.fastAfterNs)
  }

  @Test func aSlowLinkStaysOnTheSlowEncoder() {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.slow, atNs: 0)
    route.observe(Self.feedback(120), atNs: 10 * Self.fastAfterNs)

    let switched = route.update(atNs: 10 * Self.fastAfterNs)

    #expect(!switched)
    #expect(route.switchDueNs == nil)
  }

  @Test func aDropBelowTheSlowThresholdMovesBackAfterItsShorterHold() {
    var route = fastRoute()

    route.observe(bitrate: Self.slow, atNs: 2 * Self.fastAfterNs)
    route.observe(Self.feedback(20, estimate: Self.slow), atNs: 2 * Self.fastAfterNs + Self.slowAfterNs - 1)
    let early = route.update(atNs: 2 * Self.fastAfterNs + Self.slowAfterNs - 1)
    let due = route.update(atNs: 2 * Self.fastAfterNs + Self.slowAfterNs)

    #expect(!early)
    #expect(due)
    #expect(route.choice == .slow)
  }

  @Test func aLowBitrateThatFreshFeedbackDoesNotConfirmKeepsTheFastEncoder() {
    var route = fastRoute()
    let lowAt = 2 * Self.fastAfterNs

    route.observe(bitrate: Self.slow, atNs: lowAt)
    let unconfirmed = route.update(atNs: lowAt + Self.slowAfterNs)
    route.observe(Self.feedback(20), atNs: lowAt + Self.slowAfterNs + 1)
    let contradicted = route.update(atNs: lowAt + Self.slowAfterNs + 1)
    route.observe(Self.feedback(20, estimate: Self.slow), atNs: lowAt + Self.slowAfterNs + 2)
    let confirmed = route.update(atNs: lowAt + Self.slowAfterNs + 2)

    #expect(!unconfirmed)
    #expect(!contradicted)
    #expect(confirmed)
  }

  @Test func aBitrateBetweenTheThresholdsKeepsEitherEncoder() {
    let between = (ScreenSharingV2EncoderRoute.slowBelowBitrate + ScreenSharingV2EncoderRoute.fastFromBitrate) / 2
    var slow = ScreenSharingV2EncoderRoute(bitrate: between, atNs: 0)
    var fast = fastRoute()
    slow.observe(Self.feedback(20), atNs: 10 * Self.fastAfterNs)
    fast.observe(bitrate: between, atNs: 2 * Self.fastAfterNs)

    let slowSwitched = slow.update(atNs: 10 * Self.fastAfterNs)
    let fastSwitched = fast.update(atNs: 10 * Self.fastAfterNs)

    #expect(!slowSwitched)
    #expect(!fastSwitched)
    #expect((slow.choice, fast.choice) == (.slow, .fast))
  }

  @Test func afterMovingBackToTheSlowEncoderTheNextMoveUpWaitsLonger() {
    var route = fastRoute()
    route.observe(bitrate: Self.slow, atNs: 2 * Self.fastAfterNs)
    route.observe(Self.feedback(20, estimate: Self.slow), atNs: 2 * Self.fastAfterNs + Self.slowAfterNs)
    _ = route.update(atNs: 2 * Self.fastAfterNs + Self.slowAfterNs)
    let backUpAt = 3 * Self.fastAfterNs

    route.observe(bitrate: Self.fast, atNs: backUpAt)
    route.observe(Self.feedback(20), atNs: backUpAt + Self.fastAfterNs)
    let early = route.update(atNs: backUpAt + Self.fastAfterNs)
    route.observe(Self.feedback(20), atNs: backUpAt + ScreenSharingV2EncoderRoute.fastAgainAfterNs)
    let due = route.update(atNs: backUpAt + ScreenSharingV2EncoderRoute.fastAgainAfterNs)

    #expect(!early)
    #expect(due)
    #expect(route.choice == .fast)
  }

  @Test func aBriefDipDoesNotLeaveTheFastEncoder() {
    var route = fastRoute()

    route.observe(bitrate: Self.slow, atNs: 2 * Self.fastAfterNs)
    route.observe(bitrate: Self.fast, atNs: 2 * Self.fastAfterNs + Self.slowAfterNs / 2)
    let switched = route.update(atNs: 2 * Self.fastAfterNs + 2 * Self.slowAfterNs)

    #expect(!switched)
    #expect(route.choice == .fast)
  }

  private static func feedback(_ roundTripMs: Double, estimate: Int = fast) -> ScreenSharingTileNetworkFeedback {
    ScreenSharingTileNetworkFeedback(
      packetErrorRate: 0, roundTripDelayMs: roundTripMs, transmissionBitsPerSecond: estimate)
  }

  private func fastRoute() -> ScreenSharingV2EncoderRoute {
    var route = ScreenSharingV2EncoderRoute(bitrate: Self.fast, atNs: 0)
    route.observe(Self.feedback(20), atNs: Self.fastAfterNs)
    _ = route.update(atNs: Self.fastAfterNs)
    return route
  }
}
