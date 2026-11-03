import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2RecoveryGateTests {
  private static let stallNs = ScreenSharingV2RecoveryGate.stallNs

  private static func admit(
    _ gate: inout ScreenSharingV2RecoveryGate, keyframe: Bool, refresh: Bool
  ) throws -> ScreenSharingV2RecoveryGate.Admission {
    let admission = gate.admits(stream: 0, isKeyFrame: keyframe, isRefresh: refresh)
    return try #require(admission)
  }

  @Test func nothingDecodesBeforeTheFirstKeyframeNotEvenARefresh() {
    var gate = ScreenSharingV2RecoveryGate()

    let admitted = [(false, false), (false, true), (true, true), (false, false)].map {
      gate.admits(stream: 0, isKeyFrame: $0.0, isRefresh: $0.1) != nil
    }

    #expect(admitted == [false, false, true, true])
  }

  @Test func afterASkippedFrameOnlyARefreshResumesThatStream() {
    var gate = ScreenSharingV2RecoveryGate()
    _ = gate.admits(stream: 0, isKeyFrame: true, isRefresh: true)
    _ = gate.admits(stream: 1, isKeyFrame: true, isRefresh: true)

    gate.skipped(stream: 0, atNs: 0)

    let admitted = [(UInt8(0), false), (1, false), (0, true), (0, false)].map {
      gate.admits(stream: $0.0, isKeyFrame: false, isRefresh: $0.1) != nil
    }

    #expect(admitted == [false, true, true, true])
  }

  @Test func aBrokenFrameAsksForARefreshAndABrokenRefreshForAKeyframe() throws {
    var gate = ScreenSharingV2RecoveryGate()
    _ = gate.admits(stream: 0, isKeyFrame: true, isRefresh: true)
    let frame = try Self.admit(&gate, keyframe: false, refresh: false)

    let first = gate.failed(stream: 0, frame, atNs: 0)
    let refresh = try Self.admit(&gate, keyframe: false, refresh: true)
    let second = gate.failed(stream: 0, refresh, atNs: 1)

    #expect([first, second] == [.longTermReference, .keyframe])
    #expect(gate.admits(stream: 0, isKeyFrame: false, isRefresh: true) == nil)
    #expect(gate.admits(stream: 0, isKeyFrame: true, isRefresh: true) != nil)
  }

  @Test func failuresOfFramesFromBeforeTheLatestRecoveryAreIgnored() throws {
    var gate = ScreenSharingV2RecoveryGate()
    _ = gate.admits(stream: 0, isKeyFrame: true, isRefresh: true)
    let first = try Self.admit(&gate, keyframe: false, refresh: false)
    let second = try Self.admit(&gate, keyframe: false, refresh: false)
    _ = gate.failed(stream: 0, first, atNs: 0)
    _ = try Self.admit(&gate, keyframe: false, refresh: true)

    #expect(gate.failed(stream: 0, second, atNs: 1) == nil)
    #expect(gate.state(of: 0) == .decoding)
  }

  @Test func aStalledTileAsksAgainOncePerStallBoundAndReportsHowLongItWasBroken() throws {
    var gate = ScreenSharingV2RecoveryGate()
    _ = gate.admits(stream: 0, isKeyFrame: true, isRefresh: true)
    gate.skipped(stream: 0, atNs: 1_000)

    let asks = [Self.stallNs, Self.stallNs + 1_000, 2 * Self.stallNs + 999, 2 * Self.stallNs + 1_000].map {
      gate.rejected(stream: 0, atNs: $0)
    }
    let refresh = try Self.admit(&gate, keyframe: false, refresh: true)

    #expect(asks == [nil, .longTermReference, nil, .longTermReference])
    #expect(gate.decoded(stream: 0, refresh, atNs: 3 * Self.stallNs) == 3 * Self.stallNs - 1_000)
  }

  @Test func aLostDecoderSessionWaitsForAKeyframeAndAsksForOneWhenItStalls() throws {
    var gate = ScreenSharingV2RecoveryGate()
    let keyframe = try Self.admit(&gate, keyframe: true, refresh: true)

    #expect(gate.lostSession(stream: 0, keyframe, atNs: 0) == .keyframe)
    #expect(gate.admits(stream: 0, isKeyFrame: false, isRefresh: true) == nil)
    #expect(gate.rejected(stream: 0, atNs: Self.stallNs) == .keyframe)
  }

  @Test func aLostSessionReportedForAFrameFromBeforeTheLatestRecoveryIsIgnored() throws {
    var gate = ScreenSharingV2RecoveryGate()
    let first = try Self.admit(&gate, keyframe: true, refresh: true)
    let second = try Self.admit(&gate, keyframe: false, refresh: false)
    _ = gate.lostSession(stream: 0, first, atNs: 0)
    _ = try Self.admit(&gate, keyframe: true, refresh: true)

    #expect(gate.lostSession(stream: 0, second, atNs: 1) == nil)
    #expect(gate.state(of: 0) == .decoding)
  }
}
