import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2RecoveryGateTests {
  @Test func nothingDecodesBeforeTheFirstKeyframeNotEvenARefresh() {
    var gate = ScreenSharingV2RecoveryGate()

    let admitted = [(false, false), (false, true), (true, true), (false, false)].map {
      gate.admits(stream: 0, isKeyFrame: $0.0, isRefresh: $0.1)
    }

    #expect(admitted == [false, false, true, true])
  }

  @Test func afterASkippedFrameOnlyARefreshResumesThatStream() {
    var gate = ScreenSharingV2RecoveryGate()
    _ = gate.admits(stream: 0, isKeyFrame: true, isRefresh: true)
    _ = gate.admits(stream: 1, isKeyFrame: true, isRefresh: true)

    gate.broke(stream: 0)

    let admitted = [(UInt8(0), false), (1, false), (0, true), (0, false)].map {
      gate.admits(stream: $0.0, isKeyFrame: false, isRefresh: $0.1)
    }

    #expect(admitted == [false, true, true, true])
  }
}
