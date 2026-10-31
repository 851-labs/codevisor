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

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.wait(for: 1)
    transport.emit(.ltrAcked(stream: 0, token: 9))
    transport.emit(.frameLost(stream: 0, frame: 1))
    await encoder.encodes.wait(for: 2)

    #expect(encoder.acknowledgedTokens == [9])
    #expect(encoder.requests.last?.refreshes == [0: .longTermReference])
  }
}
