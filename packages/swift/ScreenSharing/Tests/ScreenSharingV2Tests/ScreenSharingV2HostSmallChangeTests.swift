import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingV2HostSmallChangeTests {
  private let transport = LoopbackMediaTransport()
  private let scheduler = ManualScheduler()

  @Test func aChangeOfAFewPixelsIsSmallForTheEncoderOnlyWhenItsTileWasSharpenedLast() async throws {
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
    encoder.emitTiles(of: encoder.requests[1])
    host.push(try Self.typed(columns: 20..<28, timestampNs: 2_000))
    await encoder.encodes.cancellableWait(for: 3)
    encoder.emitTiles(of: encoder.requests[2])
    host.push(try Self.typed(columns: 20..<36, timestampNs: 3_000))
    await encoder.encodes.cancellableWait(for: 4)

    #expect(encoder.requests.map(\.update.isRefinement) == [false, true, false, false])
    #expect(encoder.requests.map(\.smallTiles) == [[], [], [0], []])
  }

  private static func typed(columns: Range<Int>, timestampNs: Int64) throws -> ScreenSharingVideoFrame {
    let frame = try TestPixels.frame(shade: 10, timestampNs: timestampNs)
    TestPixels.paint(frame.pixelBuffer, plane: 0, rows: 100..<108, bytes: columns, value: 200)
    return frame
  }
}
