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

  @Test func aTileTheUpdateDidNotListIsComposedWithIt() {
    var assembly = ScreenSharingV2UpdateAssembly()
    let first = ScreenSharingTileUpdate(id: 1, tiles: [0])
    assembly.received(first, tile: 0)
    assembly.received(first, tile: 1)
    _ = assembly.resolve(update: 1, tile: 1, .missing)
    _ = assembly.resolve(update: 1, tile: 0, .missing)

    #expect(assembly.ready().map(\.update.id) == [1])
  }

  @Test func anOlderUpdatesTileNeverReleasesANewerUpdate() {
    var assembly = ScreenSharingV2UpdateAssembly()
    let older = ScreenSharingTileUpdate(id: 5, tiles: [0, 1])
    let newer = ScreenSharingTileUpdate(id: 6, tiles: [0, 1])
    assembly.received(older, tile: 0)
    assembly.received(newer, tile: 0)
    assembly.received(older, tile: 1)
    for (id, tile) in [(5, 0), (5, 1), (6, 0)] { _ = assembly.resolve(update: UInt32(id), tile: tile, .missing) }

    #expect(assembly.ready().map(\.update.id) == [5])
  }

  @Test func aTileOfAnUpdateAlreadyPresentedIsLateAndHoldsNothingUp() {
    var assembly = ScreenSharingV2UpdateAssembly()
    assembly.received(Self.both, tile: 0)
    _ = assembly.resolve(update: 1, tile: 0, .missing)
    assembly.received(Self.second, tile: 1)
    #expect(assembly.ready().map(\.update.id) == [1])

    assembly.received(Self.both, tile: 1)
    let current = assembly.resolve(update: 1, tile: 1, .missing)
    #expect(!current)
    _ = assembly.resolve(update: 2, tile: 1, .missing)
    #expect(assembly.ready().map(\.update.id) == [2])
  }
}
