import Testing

@testable import ScreenSharingV2

struct ScreenSharingEncoderPresentationClockTests {
  private static let frameNs: Int64 = 1_000_000_000 / 60

  @Test func framesFollowTheSubmissionTimesWhileTheyComeEveryFrame() {
    var clock = ScreenSharingEncoderPresentationClock(framesPerSecond: 60)

    let times = [5_000, 5_000 + Self.frameNs, 5_000 + 2 * Self.frameNs].map { clock.presentationNs(submittedAtNs: $0) }

    #expect(times == [5_000, 5_000 + Self.frameNs, 5_000 + 2 * Self.frameNs])
  }

  @Test func aFrameAfterALongPauseIsStampedTwoFramesAfterThePreviousOne() {
    var clock = ScreenSharingEncoderPresentationClock(framesPerSecond: 60)

    let first = clock.presentationNs(submittedAtNs: 5_000)
    let late = clock.presentationNs(submittedAtNs: 5_000 + 30 * Self.frameNs)
    let next = clock.presentationNs(submittedAtNs: 5_000 + 31 * Self.frameNs)

    #expect(late - first == 2 * 1_000_000_000 / 60)
    #expect(next - late == Self.frameNs)
  }

  @Test func framesSubmittedAtOnceStillGetIncreasingTimes() {
    var clock = ScreenSharingEncoderPresentationClock(framesPerSecond: 60)

    let times = (0..<3).map { _ in clock.presentationNs(submittedAtNs: 5_000) }

    #expect(times == [5_000, 5_001, 5_002])
  }
}
