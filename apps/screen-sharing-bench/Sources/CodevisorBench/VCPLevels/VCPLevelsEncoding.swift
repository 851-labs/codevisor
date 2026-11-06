import CoreVideo
import ScreenSharing
import ScreenSharingV2
import Synchronization

@MainActor
enum VCPLevelsEncoding {
  static let bitsPerSecond = 60_000_000
  private static let timeout = Duration.seconds(3)

  static func accessUnits(of picture: CVPixelBuffer, passes: Int) async throws -> [ScreenSharingAccessUnit] {
    let configuration = try ScreenSharingVideoConfiguration(
      width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture), bitrate: bitsPerSecond)
    let encoder = try ScreenSharingVCPTileEncoder(
      configuration: configuration,
      layout: ScreenSharingV2TileLayout(width: configuration.width, height: configuration.height, count: 1),
      metrics: ScreenSharingMetrics())
    defer { encoder.stop() }

    let outputs = Mutex<[ScreenSharingTileEncoderOutput]>([])
    encoder.onOutput { output in outputs.withLock { $0.append(output) } }
    var units: [ScreenSharingAccessUnit] = []
    for pass in 0..<passes {
      try encoder.encode(
        ScreenSharingTileEncodeRequest(
          pixelBuffer: picture, sourceTimestampNs: 1, capturedNs: 0,
          update: ScreenSharingTileUpdate(id: UInt32(pass + 1), tiles: [0], isRefinement: pass > 0)))
      switch try await output(pass, from: outputs) {
      case .tile(let tile): units.append(tile.accessUnit)
      case .unchanged, .dropped, .keyframeNeeded: continue
      case .failed(_, _, let message): throw BenchUsageError(message: "VCP pass \(pass) failed: \(message)")
      }
    }
    return units
  }

  private static func output(
    _ index: Int, from outputs: borrowing Mutex<[ScreenSharingTileEncoderOutput]>
  ) async throws -> ScreenSharingTileEncoderOutput {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let output = outputs.withLock({ $0.count > index ? $0[index] : nil }) { return output }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw BenchUsageError(message: "VCP pass \(index) produced nothing within \(timeout)")
  }
}
