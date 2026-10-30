import CoreVideo
import ScreenSharingBenchScenes

final class EncodeLabFrameSource: @unchecked Sendable {
  let config: EncodeLabConfig
  private let generator: BenchSceneGenerator
  private let scaler: EncodeLabPixelTransfer
  private let converter: EncodeLabPixelTransfer?
  private let cutter: EncodeLabTileCutter
  private var previous: CVPixelBuffer?

  init(setup: BenchSceneSetup, config: EncodeLabConfig) throws {
    self.config = config
    generator = try BenchSceneGenerator(setup: setup)
    scaler = try EncodeLabPixelTransfer(width: config.width, height: config.height, format: kCVPixelFormatType_32BGRA)
    let format = Self.inputFormat(config)
    converter = try format.map { try EncodeLabPixelTransfer(width: config.width, height: config.height, format: $0) }
    cutter = try EncodeLabTileCutter(
      width: config.width, height: config.height, tiles: config.sessionTiles,
      format: format ?? kCVPixelFormatType_32BGRA)
  }

  func picture(forVersion version: Int) async throws -> CVPixelBuffer {
    try scaler.transfer(try await nativePicture(forVersion: version))
  }

  func nativePicture(forVersion version: Int) async throws -> CVPixelBuffer {
    try await generator.frame(forVersion: version).pixelBuffer
  }

  func prepare(version: Int, forcing forced: Set<Int>) async throws -> EncodeLabPreparedFrame {
    let picture = try await picture(forVersion: version)
    let dirty = EncodeLabDirtyTiles.changed(from: previous, to: picture, tiles: config.tiles)
    previous = picture
    let encoded = config.encodedTiles(dirty: dirty, forced: forced)
    let input = try converter?.transfer(picture) ?? picture
    var inputs: [Int: CVPixelBuffer] = [:]
    for tile in encoded { inputs[tile] = try cutter.cut(input, tile: tile) }
    return EncodeLabPreparedFrame(version: version, picture: picture, inputs: inputs, dirtyTiles: dirty)
  }

  private static func inputFormat(_ config: EncodeLabConfig) -> OSType? {
    guard config.engine == .videoToolbox else { return config.vcpInputFormat }
    guard config.inputIsYCbCr else { return nil }

    return config.codec == .hevc444
      ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  }
}
