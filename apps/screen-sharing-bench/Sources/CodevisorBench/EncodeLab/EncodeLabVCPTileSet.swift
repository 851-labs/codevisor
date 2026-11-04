import CoreVideo

final class EncodeLabVCPTileSet: EncodeLabFrameEncoder {
  private let tiles: [EncodeLabVCPEncoder]

  init(config: EncodeLabConfig) throws {
    tiles = try (0..<config.tiles).map { tile in try EncodeLabVCPEncoder(config: config.tileSession, tile: tile) }
  }

  var outputs: [EncodeLabTileOutput] { tiles.flatMap(\.outputs) }

  func encode(
    _ inputs: [Int: CVPixelBuffer], frame: Int, tick: Int, refresh: EncodeLabRefresh?, repeats: Bool
  ) throws {
    let refreshTile = tiles.count / 2
    for (tile, pixels) in inputs.sorted(by: { $0.key < $1.key }) {
      try tiles[tile].encode(
        [tile: pixels], frame: frame, tick: tick, refresh: tile == refreshTile ? refresh : nil, repeats: repeats)
    }
  }

  func finish() {
    tiles.forEach { $0.finish() }
  }
}
