import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2UpdateAssemblyTests {
  private static let both = ScreenSharingTileUpdate(id: 1, tiles: [0, 1])
  private static let second = ScreenSharingTileUpdate(id: 2, tiles: [1])

  @Test func anUpdateIsReadyOnlyOnceEveryOneOfItsTilesIsResolved() {
    var assembly = ScreenSharingV2UpdateAssembly()
    assembly.received(Self.both, tile: 0)
    _ = assembly.resolve(update: 1, tile: 0, .missing)
    #expect(assembly.ready().isEmpty)

    assembly.received(Self.both, tile: 1)
    _ = assembly.resolve(update: 1, tile: 1, .missing)
    #expect(assembly.ready().map(\.update.id) == [1])
  }

  @Test func aCompleteUpdateWaitsForAnOlderOneSoTilesOfOneCaptureAppearTogether() {
    var assembly = ScreenSharingV2UpdateAssembly()
    assembly.received(Self.both, tile: 0)
    assembly.received(Self.both, tile: 1)
    assembly.received(Self.second, tile: 1)
    _ = assembly.resolve(update: 2, tile: 1, .missing)
    _ = assembly.resolve(update: 1, tile: 0, .missing)
    #expect(assembly.ready().isEmpty)

    _ = assembly.resolve(update: 1, tile: 1, .missing)
    #expect(assembly.ready().map(\.update.id) == [1, 2])
  }

  @Test func aNewerFrameOnAStreamReleasesAnOlderUpdateThatNeverReceivedThatTile() {
    var assembly = ScreenSharingV2UpdateAssembly()
    assembly.received(Self.both, tile: 0)
    _ = assembly.resolve(update: 1, tile: 0, .missing)
    assembly.received(Self.second, tile: 1)

    #expect(assembly.ready().map(\.update.id) == [1])
  }

  @Test func aSkippedFrameReleasesTheOldestUpdateStillWaitingForThatTile() {
    var assembly = ScreenSharingV2UpdateAssembly()
    assembly.received(Self.both, tile: 0)
    _ = assembly.resolve(update: 1, tile: 0, .missing)
    assembly.skipped(tile: 1)

    #expect(assembly.ready().map(\.update.id) == [1])
  }
}
