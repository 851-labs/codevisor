import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingV2HostSmallChangeTests {
  private static let admissionRetryNs: Int64 = 10_000_000

  private let transport = LoopbackMediaTransport()
  private let scheduler = ManualScheduler()
  private let metrics = ScreenSharingMetrics()

  @Test func aChangeOfAFewPixelsIsSmallForTheEncoderOnlyWhenItsTileWasSharpenedLast() async throws {
    let encoder = RecordingTileEncoder(keepsItsCapForSmallChanges: true)
    let host = try await sharpened(encoder)
    defer { host.stop() }

    host.push(try Self.typed(columns: 20..<28, timestampNs: 2_000))
    await encoder.encodes.cancellableWait(for: 3)
    encoder.emitTiles(of: encoder.requests[2])
    host.push(try Self.typed(columns: 20..<36, timestampNs: 3_000))
    await encoder.encodes.cancellableWait(for: 4)

    #expect(encoder.requests.map(\.update.isRefinement) == [false, true, false, false])
    #expect(encoder.requests.map(\.smallTiles) == [[], [], [0], []])
    #expect(metrics.counter("smallChangeRequests") == 1)
  }

  @Test func anEncoderThatDoesNotKeepItsCapIsNeverToldAChangeIsSmall() async throws {
    let encoder = RecordingTileEncoder(keepsItsCapForSmallChanges: false)
    let host = try await sharpened(encoder)
    defer { host.stop() }

    host.push(try Self.typed(columns: 20..<28, timestampNs: 2_000))
    await encoder.encodes.cancellableWait(for: 3)

    #expect(encoder.requests.map(\.smallTiles) == [[], [], []])
    #expect(metrics.counter("smallChangeRequests") == 0)
  }

  @Test func aSmallChangeThatAlsoRefreshesItsTileIsNotSmall() async throws {
    let encoder = RecordingTileEncoder(keepsItsCapForSmallChanges: true)
    let host = try await sharpened(encoder)
    defer { host.stop() }
    let checksSoFar = transport.admissionChecks.value

    transport.setAdmits(false)
    transport.emit(.frameLost(stream: 0, frame: 0))
    await transport.admissionChecks.cancellableWait(for: checksSoFar + 1)
    host.push(try Self.typed(columns: 20..<28, timestampNs: 2_000))
    await transport.admissionChecks.cancellableWait(for: checksSoFar + 2)
    transport.setAdmits(true)
    scheduler.advance(byNs: Self.admissionRetryNs)
    await encoder.encodes.cancellableWait(for: 3)

    #expect(encoder.requests[2].sourceTimestampNs == 2_000)
    #expect(encoder.requests[2].refreshes == [0: .keyframe])
    #expect(encoder.requests[2].smallTiles.isEmpty)
    #expect(metrics.counter("smallChangeRequests") == 0)
  }

  private func sharpened(_ encoder: RecordingTileEncoder) async throws -> ScreenSharingV2Host {
    let host = ScreenSharingV2Host(
      transport: transport, encoder: encoder, metrics: metrics,
      initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: scheduler, refreshPhase: .everyNanosecond)
    host.start()
    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
    await encoder.encodes.cancellableWait(for: 2)
    encoder.emitTiles(of: encoder.requests[1])
    return host
  }

  private static func typed(columns: Range<Int>, timestampNs: Int64) throws -> ScreenSharingVideoFrame {
    let frame = try TestPixels.frame(shade: 10, timestampNs: timestampNs)
    TestPixels.paint(frame.pixelBuffer, plane: 0, rows: 100..<108, bytes: columns, value: 200)
    return frame
  }
}
