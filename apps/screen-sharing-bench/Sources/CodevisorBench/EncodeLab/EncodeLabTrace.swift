struct EncodeLabTrace: Sendable {
  let config: EncodeLabConfig
  let events: [EncodeLabFrameEvent]
  let warmUpTicks: Int
  let ticks: Int
  private let outputsByFrame: [Int: [EncodeLabTileOutput]]

  init(config: EncodeLabConfig, events: [EncodeLabFrameEvent], outputs: [EncodeLabTileOutput], warmUpTicks: Int, ticks: Int) {
    self.config = config
    self.events = events
    self.warmUpTicks = warmUpTicks
    self.ticks = ticks
    outputsByFrame = Dictionary(grouping: outputs, by: \.frame).mapValues { $0.sorted { $0.tile < $1.tile } }
  }

  var refreshTile: Int? { config.engine == .videoToolbox ? config.tiles / 2 : nil }
  var firstOutput: EncodeLabTileOutput? { outputsByFrame.keys.sorted().lazy.compactMap { outputs(ofFrame: $0).first { !$0.dropped } }.first }

  func outputs(ofFrame frame: Int) -> [EncodeLabTileOutput] {
    outputsByFrame[frame] ?? []
  }
}
