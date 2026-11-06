import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingV2

struct ScreenSharingV2ViewerTimingTests {
  private static let ms: Int64 = 1_000_000
  private static let update = ScreenSharingTileUpdate(id: 9, tiles: [0, 1])

  @Test func anUpdateTakesItsHostStagesHandOffAndAssemblyFromTheTileTheHostFinishedLast() throws {
    let early = Self.context(tile: 0, encodeUs: 2_000, handOffUs: 100, receivedMs: 10, assemblingUs: 1_000)
    let critical = Self.context(tile: 1, encodeUs: 5_000, handOffUs: 400, receivedMs: 12, assemblingUs: 1_500)
    let group = ScreenSharingV2UpdateAssembly.Group(
      update: Self.update, waiting: [], decoded: [early, critical])

    let timing = try #require(ScreenSharingV2ViewerTiming.composed(group, decodedNs: 15 * Self.ms))
    #expect(timing.host?.encodeUs == 5_000 && timing.host?.handOffUs == 400)
    #expect(timing.decodeInputNs == 10 * Self.ms)
    #expect(timing.assembleUs == 0, "the late tile's packets all arrived after the update started decoding")
  }

  @Test func assemblyStopsWhereDecodingStartsSoTheStagesNeverOverlap() throws {
    let early = Self.context(tile: 0, encodeUs: 2_000, handOffUs: 100, receivedMs: 10, assemblingUs: 1_000)
    let critical = Self.context(tile: 1, encodeUs: 5_000, handOffUs: 400, receivedMs: 12, assemblingUs: 3_500)
    let group = ScreenSharingV2UpdateAssembly.Group(
      update: Self.update, waiting: [], decoded: [early, critical])

    let timing = try #require(ScreenSharingV2ViewerTiming.composed(group, decodedNs: 15 * Self.ms))
    #expect(timing.assembleUs == 1_500)
  }

  @Test func aSingleTileUpdateKeepsItsWholeAssembly() throws {
    let only = Self.context(tile: 0, encodeUs: 2_000, handOffUs: 100, receivedMs: 10, assemblingUs: 2_500)
    let group = ScreenSharingV2UpdateAssembly.Group(
      update: ScreenSharingTileUpdate(id: 9, tiles: [0]), waiting: [], decoded: [only])

    #expect(try #require(ScreenSharingV2ViewerTiming.composed(group, decodedNs: 15 * Self.ms)).assembleUs == 2_500)
  }

  private static func context(
    tile: Int, encodeUs: UInt32, handOffUs: UInt32, receivedMs: Int64, assemblingUs: UInt64
  ) -> ScreenSharingV2DecodeContext {
    let meta = ScreenSharingV2FrameMeta(
      sourceTimestampNs: 1, clock: 3, captureUs: 1_000, admissionUs: 1_000, encodeUs: encodeUs, handOffUs: handOffUs,
      isRefresh: false, update: update, layout: ScreenSharingV2TileLayout(width: 640, height: 360, count: 2))
    let frame = ScreenSharingReceivedFrame(
      stream: UInt8(tile), frame: update.id, isKeyFrame: false, ltrToken: nil, meta: meta.data,
      payload: ScreenSharingAccessUnit(Data()), assemblingUs: assemblingUs, recovery: .none)
    return ScreenSharingV2DecodeContext(
      frame: frame, meta: meta, receivedNs: receivedMs * ms, submittedNs: receivedMs * ms
    ) { _ in }
  }
}
