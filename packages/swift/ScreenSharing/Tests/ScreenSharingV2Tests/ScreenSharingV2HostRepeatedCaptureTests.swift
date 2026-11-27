import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingV2HostRepeatedCaptureTests {
  private let transport = LoopbackMediaTransport()
  private let scheduler = ManualScheduler()

  @Test func aDroppedRefinementEncodedAgainAsAChangeSaysItRepeatsItsCaptureAndANewCaptureDoesNot() async throws {
    let encoder = RecordingTileEncoder()
    let host = ScreenSharingV2Host(
      transport: transport, encoder: encoder, metrics: ScreenSharingMetrics(),
      initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: scheduler, refreshPhase: .everyNanosecond)
    host.start()
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
    await encoder.encodes.cancellableWait(for: 2)
    encoder.emit(.dropped(tile: 0, refresh: nil))
    await encoder.encodes.cancellableWait(for: 3)
    encoder.emitTiles(of: encoder.requests[2])
    host.push(try TestPixels.frame(shade: 20, timestampNs: 2_000))
    await encoder.encodes.cancellableWait(for: 4)

    let updates = encoder.requests.map(\.update)
    #expect(updates.map(\.isRefinement) == [false, true, false, false])
    #expect(updates.map(\.repeatsCapture) == [false, true, true, false])
    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000, 1_000, 1_000, 2_000])
  }
}
