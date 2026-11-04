import Testing

@testable import ScreenSharing

struct ScreenSharingCommitLogTests {
  @Test func aPresentationLandsOnItsCommitEvenAfterOlderCommitsFallOut() {
    let log = ScreenSharingCommitLog()
    var entries: [Int] = []
    for index in 0..<(ScreenSharingCommitLog.capacity + 2) {
      entries.append(
        log.record(.init(committedNs: Int64(index), rtpTimestamp: UInt32(index), sourceTimestampNs: Int64(index))))
    }
    log.presented(entries[0], at: 1)
    log.presented(entries[entries.count - 1], at: 2)

    let all = log.all()
    #expect(all.count == ScreenSharingCommitLog.capacity)
    #expect(all.first?.committedNs == 2)
    #expect(all.last?.presentedAt == 2)
    #expect(all.dropLast().allSatisfy { $0.presentedAt == nil })
  }
}
