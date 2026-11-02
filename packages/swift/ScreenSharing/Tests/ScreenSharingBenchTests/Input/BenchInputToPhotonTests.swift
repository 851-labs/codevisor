import ScreenSharingBench
import Testing

struct BenchInputToPhotonTests {
  @Test func keysAndClicksAreTimedTogetherAndEachKindOnItsOwn() {
    let observations = [
      BenchObservation(ptsNs: 0, callbackNs: 0, reading: .version(1)),
      BenchObservation(ptsNs: 50_000_000, callbackNs: 0, reading: .version(2)),
      BenchObservation(ptsNs: 330_000_000, callbackNs: 0, reading: .version(3)),
      BenchObservation(ptsNs: 700_000_000, callbackNs: 0, reading: .version(4)),
    ]
    let events = [
      BenchInputEvent(kind: .key, postedNs: 20_000_000),
      BenchInputEvent(kind: .click, postedNs: 310_000_000),
      BenchInputEvent(kind: .key, postedNs: 640_000_000),
      BenchInputEvent(kind: .click, postedNs: 900_000_000),
    ]

    let toPhoton = BenchInputToPhoton(events: events, observations: observations)

    #expect(toPhoton.events == 4)
    #expect(toPhoton.delaysMs == [30, 20, 60])
    #expect(toPhoton.unansweredEvents == 1)
    #expect(toPhoton.byKind[.key] == BenchDistribution([30, 60]))
    #expect(toPhoton.byKind[.click] == BenchDistribution([20]))
  }
}
