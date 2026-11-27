import CoreGraphics
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingV2HostRepeatedCaptureTests {
  private let transport = LoopbackMediaTransport()
  private let scheduler = ManualScheduler()

  @Test func aDroppedRefinementEncodedAgainAsAChangeRepeatsItsCaptureAndANewCaptureDoesNot() async throws {
    let encoder = RecordingTileEncoder()
    let host = started(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
    await encoder.encodes.cancellableWait(for: 2)
    encoder.emit(.dropped(tile: 0, refresh: nil, repeatsCapture: true))
    await encoder.encodes.cancellableWait(for: 3)
    encoder.emitTiles(of: encoder.requests[2])
    host.push(try TestPixels.frame(shade: 20, timestampNs: 2_000))
    await encoder.encodes.cancellableWait(for: 4)

    #expect(encoder.requests.map(\.update.isRefinement) == [false, true, false, false])
    #expect(encoder.requests.map(\.repeatedTiles) == [[], [0], [0], []])
    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000, 1_000, 1_000, 2_000])
  }

  @Test func aDroppedFirstEncodeOfANewCaptureIsEncodedAgainAsItsOwnChange() async throws {
    let encoder = RecordingTileEncoder()
    let host = started(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emit(.dropped(tile: 0, refresh: nil))
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.requests.map(\.update.isRefinement) == [false, false])
    #expect(encoder.requests.map(\.repeatedTiles) == [[], []])
    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000, 1_000])
  }

  @Test func aRefinementDroppedAfterANewerChangeStartedIsStillARepeatOfItsTile() async throws {
    let encoder = RecordingTileEncoder(layout: ScreenSharingV2TileLayout(width: 640, height: 360, count: 4))
    let host = started(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
    await encoder.encodes.cancellableWait(for: 2)
    host.push(
      try TestPixels.frame(shade: 20, timestampNs: 2_000, dirtyRects: [CGRect(x: 0, y: 0, width: 4, height: 4)]))
    await encoder.encodes.cancellableWait(for: 3)
    encoder.emit(.dropped(tile: 0, refresh: nil, repeatsCapture: true))
    await encoder.encodes.cancellableWait(for: 4)

    #expect(encoder.requests.map(\.update.isRefinement) == [false, true, false, false])
    #expect(encoder.requests.map(\.update.tiles) == [[0, 1, 2, 3], [0], [0], [0]])
    #expect(encoder.requests.map(\.repeatedTiles) == [[], [0], [], [0]])
    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000, 1_000, 2_000, 2_000])
  }

  @Test func aRepeatWhoseEncodeThrowsIsStillARepeatWhenItIsEncodedAgain() async throws {
    let recording = RecordingTileEncoder()
    let encoder = FailingTileEncoder(recording)
    let host = started(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await recording.encodes.cancellableWait(for: 1)
    recording.emitTiles(of: recording.requests[0])
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
    await recording.encodes.cancellableWait(for: 2)
    encoder.fail(.throwsOnEncode)
    recording.emit(.dropped(tile: 0, refresh: nil, repeatsCapture: true))
    await encoder.thrown.cancellableWait(for: 1)
    encoder.fail(.none)
    transport.emit(.frameAcked(ScreenSharingFrameAck(stream: 0, frame: 0, queuedUs: 0, sendingUs: 0, ackedAfterUs: 0)))
    await recording.encodes.cancellableWait(for: 3)

    #expect(recording.requests.map(\.update.isRefinement) == [false, true, false])
    #expect(recording.requests.map(\.repeatedTiles) == [[], [0], [0]])
    #expect(recording.requests.map(\.sourceTimestampNs) == [1_000, 1_000, 1_000])
  }

  private func started(_ encoder: any ScreenSharingTileEncoder) -> ScreenSharingV2Host {
    let host = ScreenSharingV2Host(
      transport: transport, encoder: encoder, metrics: ScreenSharingMetrics(),
      initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: scheduler, refreshPhase: .everyNanosecond)
    host.start()
    return host
  }
}
