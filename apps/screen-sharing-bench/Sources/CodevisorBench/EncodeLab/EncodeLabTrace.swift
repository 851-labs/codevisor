struct EncodeLabTrace: Sendable {
  let config: EncodeLabConfig
  let events: [EncodeLabFrameEvent]
  let outputs: [[EncodeLabTileOutput]]
  let warmUpTicks: Int
  let ticks: Int

  var refreshTile: Int { config.tiles / 2 }

  func outputs(ofFrame frame: Int) -> [EncodeLabTileOutput] {
    outputs.compactMap { tile in tile.first { $0.frame == frame } }
  }
}
