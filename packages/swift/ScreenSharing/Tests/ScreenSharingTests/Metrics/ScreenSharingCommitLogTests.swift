import Testing

@testable import ScreenSharing

struct ScreenSharingCommitLogTests {
  @Test func nothingIsRecordedUntilRecordingIsOn() {
    let log = ScreenSharingCommitLog()

    #expect(log.record(.init(committedNs: 1, rtpTimestamp: 1, sourceTimestampNs: 1)) == nil)
    #expect(log.all().isEmpty)
  }

  @Test func aPresentationLandsOnItsCommitAndCommitsThatFellOutAreIgnored() {
    let log = ScreenSharingCommitLog()
    log.isRecording = true
    var entries: [Int] = []
    for index in 0..<(ScreenSharingCommitLog.capacity + 2) {
      entries.append(
        log.record(.init(committedNs: Int64(index), rtpTimestamp: UInt32(index), sourceTimestampNs: Int64(index)))!)
    }
    log.presented(entries[0], atNs: 1)
    log.presented(entries[entries.count - 1], atNs: 2)

    let all = log.all()
    #expect(all.count == ScreenSharingCommitLog.capacity)
    #expect(all.first?.committedNs == 2)
    #expect(all.last?.presentedNs == 2)
    #expect(all.dropLast().allSatisfy { $0.presentedNs == nil })
  }
}
