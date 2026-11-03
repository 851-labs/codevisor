import CoreVideo
import ScreenSharing
import Synchronization

enum ScreenSharingVCPSelfTest {
  static let width = 512
  static let height = 256
  static let tiles = 4
  static let timeout = Duration.seconds(2)

  private static let outcome = Mutex<Result<Void, ScreenSharingError>?>(nil)

  static func pass() async throws {
    if let known = outcome.withLock({ $0 }) { return try known.get() }

    let result: Result<Void, ScreenSharingError>
    do {
      try await run()
      result = .success(())
    } catch {
      result = .failure(.unavailable("VCP self-test failed: \(error.localizedDescription)"))
    }
    outcome.withLock { $0 = result }
    try result.get()
  }

  private static func run() async throws {
    let encoder = try ScreenSharingVCPTileEncoder(
      configuration: try ScreenSharingVideoConfiguration(width: width, height: height),
      layout: ScreenSharingV2TileLayout(width: width, height: height, count: tiles), metrics: ScreenSharingMetrics())
    defer { encoder.stop() }

    let outputs = ScreenSharingVCPSelfTestOutputs(expected: tiles)
    encoder.onOutput { outputs.add($0) }
    try encoder.encode(
      ScreenSharingTileEncodeRequest(
        pixelBuffer: try blankFrame(), sourceTimestampNs: 1, capturedNs: 1,
        update: ScreenSharingTileUpdate(id: 1, tiles: Set(0..<tiles))))
    try check(await outputs.all(within: timeout))
  }

  private static func check(_ outputs: [ScreenSharingTileEncoderOutput]) throws {
    let keyframes = outputs.compactMap { output -> Int? in
      guard case .tile(let tile) = output, tile.isKeyFrame else { return nil }

      return tile.tile
    }
    guard keyframes.sorted() == Array(0..<tiles) else {
      throw ScreenSharingError.unavailable("VCP self-test got \(outputs) instead of \(tiles) keyframe tiles.")
    }
  }

  private static func blankFrame() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
    guard let buffer else { throw ScreenSharingError.unavailable("No VCP self-test frame.") }

    return buffer
  }
}
