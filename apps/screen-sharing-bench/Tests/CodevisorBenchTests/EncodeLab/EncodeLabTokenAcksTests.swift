import Testing

@testable import CodevisorBench

struct EncodeLabTokenAcksTests {
  @Test func acknowledgesEachTokenOnceAfterTheRoundTrip() {
    var acks = EncodeLabTokenAcks(roundTripNs: 16_000_000)
    acks.received(token: 7, atNs: 1_000)

    #expect(acks.takeDue(atNs: 16_000_999).isEmpty)
    #expect(acks.takeDue(atNs: 16_001_000) == [7])
    #expect(acks.takeDue(atNs: 40_000_000).isEmpty)
  }
}
