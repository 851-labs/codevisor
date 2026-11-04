import CoreVideo

final class EncodeLabTileSet: EncodeLabFrameEncoder {
  private let tiles: [EncodeLabTileEncoder]

  init(config: EncodeLabConfig) throws {
    let factory = EncodeLabSessionFactory(config: config, width: config.width, height: config.tileHeight)
    tiles = try (0..<config.tiles).map { tile in
      EncodeLabTileEncoder(tile: tile, session: try factory.make(), config: config)
    }
  }

  var outputs: [EncodeLabTileOutput] { tiles.flatMap(\.outputs) }

  func encode(
    _ inputs: [Int: CVPixelBuffer], frame: Int, tick: Int, refresh: EncodeLabRefresh?, repeats: Bool
  ) throws {
    let refreshTile = tiles.count / 2
    for (tile, pixels) in inputs.sorted(by: { $0.key < $1.key }) {
      try tiles[tile].encode(
        pixels, frame: frame, tick: tick, refresh: tile == refreshTile ? refresh : nil, repeats: repeats)
    }
  }

  func finish() {
    tiles.forEach { $0.finish() }
  }
}
