import Testing

@testable import CodevisorBench

struct EncodeLabLTRAcksTests {
  @Test func acknowledgesEachTokenOnceAfterTheRoundTrip() {
    var acks = EncodeLabLTRAcks()
    acks.received(token: 7, atNs: 1_000)

    #expect(acks.takeDue(atNs: 1_000 + EncodeLabLTRAcks.roundTripNs - 1).isEmpty)
    #expect(acks.takeDue(atNs: 1_000 + EncodeLabLTRAcks.roundTripNs) == [7])
    #expect(acks.takeDue(atNs: 1_000 + 2 * EncodeLabLTRAcks.roundTripNs).isEmpty)
  }
}
