import ScreenSharingBench
import Testing

struct BenchInputResponsesTests {
  @Test func eachEventIsAnsweredByTheFirstFrameShowingAnotherVersion() {
    let observations = [
      BenchObservation(ptsNs: 10_000_000, callbackNs: 0, reading: .version(5)),
      BenchObservation(ptsNs: 40_000_000, callbackNs: 0, reading: .checksumMismatch),
      BenchObservation(ptsNs: 50_000_000, callbackNs: 0, reading: .version(5)),
      BenchObservation(ptsNs: 60_000_000, callbackNs: 0, reading: .version(6)),
      BenchObservation(ptsNs: 76_000_000, callbackNs: 0, reading: .version(6)),
      BenchObservation(ptsNs: 330_000_000, callbackNs: 0, reading: .version(7)),
    ]

    let responses = BenchInputResponses(eventsNs: [300_000_000, 20_000_000], observations: observations)

    #expect(responses.delaysMs == [40, 30])
    #expect(responses.unansweredEvents == 0)
  }

  @Test func anEventBeforeAnyReadableFrameHasNoKnownStartingVersionAndGoesUnanswered() {
    let observations = [
      BenchObservation(ptsNs: 5_000_000, callbackNs: 0, reading: .checksumMismatch),
      BenchObservation(ptsNs: 30_000_000, callbackNs: 0, reading: .version(4)),
    ]

    let responses = BenchInputResponses(eventsNs: [10_000_000], observations: observations)

    #expect(responses.delaysMs.isEmpty)
    #expect(responses.unansweredEvents == 1)
  }

  @Test func aChangeLandingAfterTheNextEventLeavesBothEventsUnansweredBecauseEitherCouldOwnIt() {
    let observations = [
      BenchObservation(ptsNs: 10_000_000, callbackNs: 0, reading: .version(1)),
      BenchObservation(ptsNs: 200_000_000, callbackNs: 0, reading: .version(2)),
      BenchObservation(ptsNs: 480_000_000, callbackNs: 0, reading: .version(3)),
    ]

    let responses = BenchInputResponses(
      eventsNs: [20_000_000, 160_000_000, 450_000_000], observations: observations)

    #expect(responses.delaysMs == [30])
    #expect(responses.unansweredEvents == 2)
  }
}
