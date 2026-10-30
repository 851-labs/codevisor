struct EncodeLabTrace: Sendable {
  let config: EncodeLabConfig
  let events: [EncodeLabFrameEvent]
  let outputs: [EncodeLabTileOutput]
  let warmUpTicks: Int
  let ticks: Int

  var refreshTile: Int? { config.engine == .videoToolbox ? config.tiles / 2 : nil }

  func outputs(ofFrame frame: Int) -> [EncodeLabTileOutput] {
    outputs.filter { $0.frame == frame }.sorted { $0.tile < $1.tile }
  }
}
