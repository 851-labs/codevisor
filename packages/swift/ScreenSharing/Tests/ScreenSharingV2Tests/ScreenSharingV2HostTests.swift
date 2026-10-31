import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingV2HostTests {
  private let transport = LoopbackMediaTransport()
  private let encoder = RecordingTileEncoder()

  private func startedHost() -> ScreenSharingV2Host {
    let host = ScreenSharingV2Host(transport: transport, encoder: encoder, metrics: ScreenSharingMetrics())
    host.start()
    return host
  }

  @Test func aCaptureWaitsForAdmissionInsteadOfQueueingBehindTheSendBacklog() async throws {
    let host = startedHost()
    defer { host.stop() }
    transport.setAdmits(false)

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await transport.admissionChecks.wait(for: 1)
    #expect(encoder.encodes.value == 0)

    transport.setAdmits(true)
    await encoder.encodes.wait(for: 1)
    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000])
  }

  @Test func aLossBeforeAnyAcknowledgedReferenceReencodesTheLastCaptureAsAKeyframe() async throws {
    let host = startedHost()
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.wait(for: 1)
    transport.emit(.frameLost(stream: 0, frame: 0))
    await encoder.encodes.wait(for: 2)

    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000, 1_000])
    #expect(encoder.requests.map(\.refreshes) == [[:], [0: .keyframe]])
  }

  @Test func aLossAfterAnAcknowledgedReferenceAsksForALongTermReferenceRefresh() async throws {
    let host = startedHost()
    defer { host.stop() }

    try await sendFirstFrame(through: host, keyframe: true, token: 9)
    transport.emit(.ltrAcked(stream: 0, token: 9))
    transport.emit(.frameLost(stream: 0, frame: 1))
    await encoder.encodes.wait(for: 2)

    #expect(encoder.acknowledgedTokens == [9])
    #expect(encoder.requests.last?.refreshes == [0: .longTermReference])
  }

  @Test func anAcknowledgedReferenceFromBeforeTheLatestKeyframeNoLongerCounts() async throws {
    let host = startedHost()
    defer { host.stop() }

    try await sendFirstFrame(through: host, keyframe: true, token: 9)
    host.push(try TestPixels.frame(shade: 20, timestampNs: 2_000))
    await encoder.encodes.wait(for: 2)
    encoder.emitTile(of: encoder.requests[1], keyframe: true, token: nil)
    await transport.sends.wait(for: 2)
    transport.emit(.ltrAcked(stream: 0, token: 9))
    transport.emit(.frameLost(stream: 0, frame: 1))
    await encoder.encodes.wait(for: 3)

    #expect(encoder.acknowledgedTokens.isEmpty)
    #expect(encoder.requests.last?.refreshes == [0: .keyframe])
  }

  @Test func aRefreshTheEncoderDroppedIsAskedForAgainFromTheLastCapture() async throws {
    let host = startedHost()
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.wait(for: 1)
    encoder.emit(.dropped(tile: 0, refresh: .keyframe))
    await encoder.encodes.wait(for: 2)

    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000, 1_000])
    #expect(encoder.requests.last?.refreshes == [0: .keyframe])
  }

  private func sendFirstFrame(through host: ScreenSharingV2Host, keyframe: Bool, token: UInt64?) async throws {
    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.wait(for: 1)
    encoder.emitTile(of: encoder.requests[0], keyframe: keyframe, token: token)
    await transport.sends.wait(for: 1)
  }
}
