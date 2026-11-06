import CoreGraphics
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingV2HostTests {
  private static let tiled = ScreenSharingV2TileLayout(width: 640, height: 360, count: 4)

  private let transport = LoopbackMediaTransport()
  private let scheduler = ManualScheduler()

  private func startedHost(
    _ encoder: RecordingTileEncoder, refinement: ScreenSharingV2RefinementPolicy? = nil,
    refreshPhase: ScreenSharingV2RefreshPhase = .everyNanosecond
  ) -> ScreenSharingV2Host {
    let host = ScreenSharingV2Host(
      transport: transport, encoder: encoder, metrics: ScreenSharingMetrics(),
      initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: scheduler, refinement: refinement,
      refreshPhase: refreshPhase)
    host.start()
    return host
  }

  @Test func theFirstCaptureEncodesEveryTileAndLaterOnesOnlyTheTilesTheirDirtyRectsTouch() async throws {
    let encoder = RecordingTileEncoder(layout: Self.tiled)
    let host = startedHost(encoder)
    defer { host.stop() }

    host.push(
      try TestPixels.frame(shade: 10, timestampNs: 1_000, dirtyRects: [CGRect(x: 0, y: 0, width: 4, height: 4)]))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    host.push(
      try TestPixels.frame(shade: 20, timestampNs: 2_000, dirtyRects: [CGRect(x: 30, y: 100, width: 8, height: 100)]))
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.requests.map(\.update.tiles) == [[0, 1, 2, 3], [1, 2]])
    #expect(encoder.requests.map(\.update.isRefinement) == [false, false])
  }

  @Test func aChangeStartsWhileOneIsEncodingAndCapturesBeyondThatWaitWithEveryTileTheyDirtied() async throws {
    let encoder = RecordingTileEncoder(layout: Self.tiled)
    let host = startedHost(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    host.push(try TestPixels.frame(shade: 20, timestampNs: 2_000))
    await encoder.encodes.cancellableWait(for: 2)
    host.push(
      try TestPixels.frame(shade: 30, timestampNs: 3_000, dirtyRects: [CGRect(x: 0, y: 0, width: 8, height: 8)]))
    host.push(
      try TestPixels.frame(shade: 40, timestampNs: 4_000, dirtyRects: [CGRect(x: 0, y: 300, width: 8, height: 8)]))
    encoder.emitTiles(of: encoder.requests[0])
    await encoder.encodes.cancellableWait(for: 3)
    host.stop()

    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000, 2_000, 4_000])
    #expect(encoder.requests.last?.update.tiles == [0, 3])
  }

  @Test func idleTilesAreRefinedOneAtATimeForEachPassAndThenLeftAlone() async throws {
    let encoder = RecordingTileEncoder(layout: Self.tiled)
    let host = startedHost(encoder)

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    var encoded = 1
    for pass in 1...ScreenSharingV2Profile.refinementPasses {
      await scheduler.scheduled.cancellableWait(for: pass)
      scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
      for _ in Self.tiled.tiles {
        await encoder.encodes.cancellableWait(for: encoded + 1)
        encoder.emitTiles(of: encoder.requests[encoded])
        encoded += 1
      }
    }
    host.stop()

    let refinements = encoder.requests.dropFirst()
    #expect(refinements.allSatisfy { $0.update.isRefinement && $0.update.tiles.count == 1 })
    #expect(refinements.allSatisfy { $0.sourceTimestampNs == 1_000 })
    let passes = Dictionary(grouping: refinements.flatMap(\.update.tiles), by: { $0 }).mapValues(\.count)
    #expect(passes == [0: 4, 1: 4, 2: 4, 3: 4])
    #expect(scheduler.scheduled.value == ScreenSharingV2Profile.refinementPasses)
  }

  @Test func aRefinementWaitsForTheOffsetAfterTheRefreshItIsDueIn() async throws {
    let encoder = RecordingTileEncoder(layout: Self.tiled)
    let host = startedHost(
      encoder, refreshPhase: ScreenSharingV2RefreshPhase(periodNs: 10_000_000, offsetNs: 2_000_000))
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: scheduler.nowNs))
    await encoder.encodes.wait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    await scheduler.scheduled.wait(for: 1)

    #expect(scheduler.dueTimesNs == [1_042_000_000])
  }

  @Test func anEventBeforeTheAlignedWakeDoesNotStartTheRefinementEarly() async throws {
    let encoder = RecordingTileEncoder(layout: Self.tiled)
    let host = startedHost(
      encoder, refreshPhase: ScreenSharingV2RefreshPhase(periodNs: 10_000_000, offsetNs: 2_000_000))

    let anchorNs = scheduler.nowNs
    host.push(try TestPixels.frame(shade: 10, timestampNs: anchorNs))
    await encoder.encodes.wait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    await scheduler.scheduled.wait(for: 1)
    scheduler.advance(byNs: 36_000_000)
    host.push(try TestPixels.frame(shade: 10, timestampNs: anchorNs + 30_000_000))
    host.stop()

    #expect(encoder.requests.map(\.update.isRefinement) == [false])
  }

  @Test func aTileThatChangesAgainStartsItsRefinementPassesOver() async throws {
    let encoder = RecordingTileEncoder(layout: Self.tiled)
    let host = startedHost(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs / 2)
    host.push(
      try TestPixels.frame(shade: 20, timestampNs: 2_000, dirtyRects: [CGRect(x: 0, y: 0, width: 8, height: 8)]))
    await encoder.encodes.cancellableWait(for: 2)
    encoder.emitTiles(of: encoder.requests[1])
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs - ScreenSharingV2Profile.refinementGapNs / 2)
    for index in 2...4 {
      await encoder.encodes.cancellableWait(for: index + 1)
      encoder.emitTiles(of: encoder.requests[index])
    }
    await scheduler.scheduled.cancellableWait(for: 2)

    #expect(encoder.requests[1].update.tiles == [0])
    #expect(encoder.requests[2...4].map(\.update.tiles) == [[1], [2], [3]])
    #expect(encoder.requests[2...4].allSatisfy { $0.update.isRefinement && $0.sourceTimestampNs == 2_000 })
  }

  @Test func aChangeStartsWhileAnotherTileIsStillBeingRefined() async throws {
    let encoder = RecordingTileEncoder(layout: Self.tiled)
    let host = startedHost(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
    await encoder.encodes.cancellableWait(for: 2)
    host.push(
      try TestPixels.frame(shade: 20, timestampNs: 2_000, dirtyRects: [CGRect(x: 0, y: 300, width: 8, height: 8)]))
    await encoder.encodes.cancellableWait(for: 3)

    #expect(encoder.requests[1].update.tiles == [0])
    #expect(encoder.requests[2].update.tiles == [3])
    #expect(encoder.requests[2].update.isRefinement == false)
  }

  @Test func anUnchangedTileIsNotEncodedAgainAndEndsItsRefinement() async throws {
    let encoder = RecordingTileEncoder()
    let host = startedHost(encoder)

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
    await encoder.encodes.cancellableWait(for: 2)
    encoder.emit(.unchanged(tile: 0, update: 2))
    scheduler.advance(byNs: 4 * ScreenSharingV2Profile.refinementGapNs)
    host.stop()

    #expect(encoder.requests.count == 2)
    #expect(scheduler.scheduled.value == 1)
  }

  @Test func aRefinementPassThatEncodesToAlmostNothingUnderTheEncodersPolicyEndsTheTilesRefinement() async throws {
    let encoder = RecordingTileEncoder(
      refinementPolicy: ScreenSharingV2RefinementPolicy(passes: 4, convergedBelowBytes: 64))
    let host = startedHost(encoder)

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
    await encoder.encodes.cancellableWait(for: 2)
    encoder.emitTiles(of: encoder.requests[1])
    await transport.sends.cancellableWait(for: 2)
    scheduler.advance(byNs: 4 * ScreenSharingV2Profile.refinementGapNs)
    host.stop()

    #expect(encoder.requests.map(\.update.isRefinement) == [false, true])
    #expect(scheduler.scheduled.value == 1)
  }

  @Test func aReportedDirtyTileWhosePixelsDidNotChangeIsSkipped() async throws {
    let encoder = RecordingTileEncoder(layout: Self.tiled)
    let host = startedHost(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shades: [10, 20, 30, 40], timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    host.push(
      try TestPixels.frame(
        shades: [10, 20, 99, 40], timestampNs: 2_000, dirtyRects: [CGRect(x: 0, y: 0, width: 640, height: 360)]))
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.requests[1].update.tiles == [1, 2])
  }

  @Test func anUnchangedAnswerOlderThanTheTilesLatestChangeLeavesItsRefinementAlone() async throws {
    let encoder = RecordingTileEncoder()
    let host = startedHost(encoder)

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
    await encoder.encodes.cancellableWait(for: 2)
    encoder.emit(.unchanged(tile: 0, update: 2))
    host.push(try TestPixels.frame(shade: 20, timestampNs: 2_000))
    await encoder.encodes.cancellableWait(for: 3)
    encoder.emitTiles(of: encoder.requests[2])
    encoder.emit(.unchanged(tile: 0, update: 2))
    await scheduler.scheduled.cancellableWait(for: 2)
    scheduler.advance(byNs: ScreenSharingV2Profile.refinementGapNs)
    host.stop()

    #expect(encoder.requests.count == 4)
    #expect(encoder.requests.last?.update.isRefinement == true)
    #expect(encoder.requests.last?.sourceTimestampNs == 2_000)
  }

  private let encoder = RecordingTileEncoder()

  @Test func aCaptureWaitsForAdmissionInsteadOfQueueingBehindTheSendBacklog() async throws {
    let host = startedHost(encoder)
    defer { host.stop() }
    transport.setAdmits(false)

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await transport.admissionChecks.cancellableWait(for: 1)
    #expect(encoder.encodes.value == 0)

    transport.setAdmits(true)
    await scheduler.scheduled.cancellableWait(for: 1)
    scheduler.advance(byNs: ScreenSharingV2AdmissionRetry.delayNs(after: transport.admission()))
    await encoder.encodes.cancellableWait(for: 1)
    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000])
  }

  @Test func aLossBeforeAnyAcknowledgedReferenceReencodesTheLastCaptureAsAKeyframe() async throws {
    let host = startedHost(encoder)
    defer { host.stop() }

    try await sendFirstFrame(through: host, keyframe: true, token: nil)
    transport.emit(.frameLost(stream: 0, frame: 0))
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000, 1_000])
    #expect(encoder.requests.map(\.refreshes) == [[:], [0: .keyframe]])
  }

  @Test func aLossAfterAnAcknowledgedReferenceAsksForALongTermReferenceRefresh() async throws {
    let host = startedHost(encoder)
    defer { host.stop() }

    try await sendFirstFrame(through: host, keyframe: true, token: 9)
    transport.emit(.ltrAcked(stream: 0, token: 9))
    transport.emit(.frameLost(stream: 0, frame: 1))
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.acknowledgedTokens == [9])
    #expect(encoder.requests.last?.refreshes == [0: .longTermReference])
  }

  @Test func anAcknowledgedReferenceFromBeforeTheLatestKeyframeNoLongerCounts() async throws {
    let host = startedHost(encoder)
    defer { host.stop() }

    try await sendFirstFrame(through: host, keyframe: true, token: 9)
    host.push(try TestPixels.frame(shade: 20, timestampNs: 2_000))
    await encoder.encodes.cancellableWait(for: 2)
    encoder.emitTile(of: encoder.requests[1], keyframe: true, token: nil)
    await transport.sends.cancellableWait(for: 2)
    transport.emit(.ltrAcked(stream: 0, token: 9))
    transport.emit(.frameLost(stream: 0, frame: 1))
    await encoder.encodes.cancellableWait(for: 3)

    #expect(encoder.acknowledgedTokens.isEmpty)
    #expect(encoder.requests.last?.refreshes == [0: .keyframe])
  }

  @Test(arguments: [ScreenSharingTileRefresh.keyframe, nil])
  func aFrameTheEncoderDroppedIsEncodedAgainFromTheLastCapture(refresh: ScreenSharingTileRefresh?) async throws {
    let host = startedHost(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emit(.dropped(tile: 0, refresh: refresh))
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000, 1_000])
    #expect(encoder.requests.last?.refreshes == refresh.map { [0: $0] } ?? [:])
  }

  @Test func aKeyframeTheEncoderAsksForReencodesThatTileOfTheLastCapture() async throws {
    let encoder = RecordingTileEncoder(layout: Self.tiled)
    let host = startedHost(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTiles(of: encoder.requests[0])
    encoder.emit(.keyframeNeeded(tile: 2))
    await encoder.encodes.cancellableWait(for: 2)

    #expect(encoder.requests.map(\.sourceTimestampNs) == [1_000, 1_000])
    #expect(encoder.requests.last?.update.tiles == [2])
    #expect(encoder.requests.last?.refreshes == [2: .keyframe])
  }

  @Test func aRefreshRequestGetsALongTermReferenceRefreshAndAKeyframeRequestAKeyframe() async throws {
    let host = startedHost(encoder)
    defer { host.stop() }

    try await sendFirstFrame(through: host, keyframe: true, token: 9)
    transport.emit(.ltrAcked(stream: 0, token: 9))
    transport.emit(.refreshRequested(stream: 0, keyframe: false))
    await encoder.encodes.cancellableWait(for: 2)
    encoder.emitTile(of: encoder.requests[1], keyframe: false, token: nil, refresh: .longTermReference)
    transport.emit(.refreshRequested(stream: 0, keyframe: true))
    await encoder.encodes.cancellableWait(for: 3)

    #expect(encoder.requests.map(\.refreshes) == [[:], [0: .longTermReference], [0: .keyframe]])
  }

  @Test func lostRefreshesStayLongTermReferenceRefreshesOfThatTileOnly() async throws {
    let encoder = RecordingTileEncoder(layout: Self.tiled)
    let host = startedHost(encoder)
    defer { host.stop() }

    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    for tile in 0..<4 { encoder.emitTile(of: encoder.requests[0], tile: tile, keyframe: true, token: UInt64(tile)) }
    for tile in 0..<4 { transport.emit(.ltrAcked(stream: UInt8(tile), token: UInt64(tile))) }
    transport.emit(.frameLost(stream: 2, frame: 2))
    for (index, frame) in [UInt32(4), 5, 6].enumerated() {
      await encoder.encodes.cancellableWait(for: index + 2)
      encoder.emitTile(
        of: encoder.requests[index + 1], tile: 2, keyframe: false, token: nil, refresh: .longTermReference)
      transport.emit(.frameLost(stream: 2, frame: frame))
    }
    await encoder.encodes.cancellableWait(for: 5)

    #expect(encoder.requests.dropFirst().map(\.refreshes) == Array(repeating: [2: .longTermReference], count: 4))
  }

  @Test func theEncoderHearsTheNetworkWithItsFirstEncodeAndThenEvery250ms() async throws {
    let host = startedHost(encoder)
    defer { host.stop() }

    for index in 0..<2 {
      host.push(try TestPixels.frame(shade: UInt8(10 + index), timestampNs: Int64(index + 1) * 1_000))
      await encoder.encodes.cancellableWait(for: index + 1)
      encoder.emitTiles(of: encoder.requests[index])
    }
    let early = encoder.networkFeedback.count
    scheduler.advance(byNs: 250_000_000)
    await encoder.encodes.cancellableWait(for: 3)

    #expect(early == 1)
    #expect(encoder.networkFeedback.count == 2)
    #expect(encoder.networkFeedback.first?.transmissionBitsPerSecond == 100_000_000)
  }

  private func sendFirstFrame(through host: ScreenSharingV2Host, keyframe: Bool, token: UInt64?) async throws {
    host.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await encoder.encodes.cancellableWait(for: 1)
    encoder.emitTile(of: encoder.requests[0], keyframe: keyframe, token: token)
    await transport.sends.cancellableWait(for: 1)
  }
}
