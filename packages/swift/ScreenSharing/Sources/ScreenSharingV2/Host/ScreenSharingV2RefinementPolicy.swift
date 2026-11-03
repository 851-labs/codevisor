public struct ScreenSharingV2RefinementPolicy: Equatable, Sendable {
  public static let standard = ScreenSharingV2RefinementPolicy()

  public var passes: Int
  public var convergedBelowBytes: Int

  public init(
    passes: Int = ScreenSharingV2Profile.refinementPasses,
    convergedBelowBytes: Int = ScreenSharingV2Profile.refinementConvergedBelowBytes
  ) {
    self.passes = passes
    self.convergedBelowBytes = convergedBelowBytes
  }

  func converged(_ tile: ScreenSharingEncodedTile) -> Bool {
    tile.update.isRefinement && tile.accessUnit.count < convergedBelowBytes
  }
}
