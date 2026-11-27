import CoreGraphics
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingV2HostContentIntervalTests {
  private static let frameNs: Int64 = 1_000_000_000 / 60
  private static let everything = [CGRect(x: 0, y: 0, width: 640, height: 360)]

  private let transport = LoopbackMediaTransport()
  private let scheduler = ManualScheduler()

  @Test func aCaptureThatReplacedOthersCarriesTheTimeSinceTheContentLastChangedNotTheWait() async throws {
    let encoder = RecordingTileEncoder()
    let host = started(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: Self.at(frames: 0)))
    await encoder.encodes.cancellableWait(for: 1)
    for (shade, frames) in [(20, 1), (30, 2), (40, 3)] {
      host.push(try TestPixels.frame(shade: UInt8(shade), timestampNs: Self.at(frames: frames)))
    }
    encoder.emitTiles(of: encoder.requests[0])
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.requests.map(\.sourceTimestampNs) == [Self.at(frames: 0), Self.at(frames: 3)])
    #expect(encoder.requests.map(\.contentIntervalsNs) == [[:], [0: Self.frameNs]])
  }

  @Test func aCaptureThatChangedNoPixelsDoesNotRestartTheContentInterval() async throws {
    let encoder = RecordingTileEncoder()
    let host = started(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: Self.at(frames: 0)))
    await encoder.encodes.cancellableWait(for: 1)
    host.push(try TestPixels.frame(shade: 10, timestampNs: Self.at(frames: 1)))
    host.push(try TestPixels.frame(shade: 20, timestampNs: Self.at(frames: 2)))
    encoder.emitTiles(of: encoder.requests[0])
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.requests.map(\.contentIntervalsNs) == [[:], [0: 2 * Self.frameNs]])
  }

  @Test func aRefinementPassCarriesNoContentInterval() async throws {
    let encoder = RecordingTileEncoder()
    let host = started(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: Self.at(frames: 0)))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    host.push(try TestPixels.frame(shade: 20, timestampNs: Self.at(frames: 1)))
    await encoder.encodes.cancellableWait(for: 2)
    encoder.emitTiles(of: encoder.requests[1])
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
    await encoder.encodes.cancellableWait(for: 3)

    #expect(encoder.requests.map(\.update.isRefinement) == [false, false, true])
    #expect(encoder.requests.map(\.contentIntervalsNs) == [[:], [0: Self.frameNs], [:]])
  }

  @Test func aRefreshOfTheLastEncodedCaptureCarriesNoContentInterval() async throws {
    let encoder = RecordingTileEncoder()
    let host = started(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: Self.at(frames: 0)))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    host.push(try TestPixels.frame(shade: 20, timestampNs: Self.at(frames: 1)))
    await encoder.encodes.cancellableWait(for: 2)
    encoder.emitTiles(of: encoder.requests[1])
    transport.emit(.frameLost(stream: 0, frame: 1))
    await encoder.encodes.cancellableWait(for: 3)

    #expect(encoder.requests.map(\.sourceTimestampNs) == [Self.at(frames: 0), Self.at(frames: 1), Self.at(frames: 1)])
    #expect(encoder.requests[2].refreshes[0] != nil)
    #expect(encoder.requests.map(\.contentIntervalsNs) == [[:], [0: Self.frameNs], [:]])
  }

  @Test func eachTileCarriesTheTimeSinceItsOwnContentChanged() async throws {
    let encoder = RecordingTileEncoder(layout: ScreenSharingV2TileLayout(width: 640, height: 360, count: 2))
    let host = started(encoder)
    defer { host.stop() }

    for (frames, top, bottom) in [(0, 10, 10), (1, 20, 10), (2, 30, 10), (5, 30, 20)] {
      host.push(try TestPixels.frame(shades: [UInt8(top), 10, UInt8(bottom)], timestampNs: Self.at(frames: frames)))
      await encoder.encodes.cancellableWait(for: encoder.requests.count + 1)
      encoder.emitTiles(of: encoder.requests[encoder.requests.count - 1])
    }

    #expect(encoder.requests.map(\.update.tiles) == [[0, 1], [0], [0], [1]])
    let expected: [[Int: Int64]] = [[:], [0: Self.frameNs], [0: Self.frameNs], [1: 5 * Self.frameNs]]
    #expect(encoder.requests.map(\.contentIntervalsNs) == expected)
  }

  @Test func onlyAReportedTouchRestartsTheIntervalOfAWaitingTile() async throws {
    let encoder = RecordingTileEncoder()
    let host = started(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: Self.at(frames: 0)))
    await encoder.encodes.cancellableWait(for: 1)
    host.push(try TestPixels.frame(shade: 20, timestampNs: Self.at(frames: 1)))
    host.push(try TestPixels.frame(shade: 30, timestampNs: Self.at(frames: 2)))
    host.push(try TestPixels.frame(shade: 40, timestampNs: Self.at(frames: 5), dirtyRects: Self.everything))
    encoder.emitTiles(of: encoder.requests[0])
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.requests.map(\.sourceTimestampNs) == [Self.at(frames: 0), Self.at(frames: 5)])
    #expect(encoder.requests.map(\.contentIntervalsNs) == [[:], [0: 4 * Self.frameNs]])
  }

  @Test func aChangeWhoseTimestampDidNotMoveForwardCarriesTheShortestInterval() async throws {
    let encoder = RecordingTileEncoder()
    let host = started(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: Self.at(frames: 0)))
    await encoder.encodes.cancellableWait(for: 1)
    host.push(try TestPixels.frame(shade: 20, timestampNs: Self.at(frames: 1)))
    host.push(try TestPixels.frame(shade: 30, timestampNs: Self.at(frames: 1), dirtyRects: Self.everything))
    encoder.emitTiles(of: encoder.requests[0])
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.requests.map(\.contentIntervalsNs) == [[:], [0: ScreenSharingV2Profile.frameNs]])
  }

  @Test func aCaptureThatChangedNothingKeepsTheIntervalsOfTheOneItReplaced() async throws {
    let encoder = RecordingTileEncoder()
    let host = started(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: Self.at(frames: 0)))
    await encoder.encodes.cancellableWait(for: 1)
    host.push(try TestPixels.frame(shade: 20, timestampNs: Self.at(frames: 1)))
    host.push(try TestPixels.frame(shade: 20, timestampNs: Self.at(frames: 2), dirtyRects: []))
    encoder.emitTiles(of: encoder.requests[0])
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.requests.map(\.sourceTimestampNs) == [Self.at(frames: 0), Self.at(frames: 2)])
    #expect(encoder.requests.map(\.contentIntervalsNs) == [[:], [0: Self.frameNs]])
  }

  private func started(_ encoder: RecordingTileEncoder) -> ScreenSharingV2Host {
    let host = ScreenSharingV2Host(
      transport: transport, encoder: encoder, metrics: ScreenSharingMetrics(),
      initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: scheduler, refreshPhase: .everyNanosecond)
    host.start()
    return host
  }

  private static func at(frames: Int) -> Int64 {
    1_000 + Int64(frames) * frameNs
  }
}
