import CoreVideo
import ScreenSharing
import ScreenSharingV2
import Synchronization

enum EncoderReleaseFrame {
  static let timeout = Duration.seconds(5)

  static func encode(with encoder: ScreenSharingVCPTileEncoder, width: Int, height: Int) async throws -> Int {
    let tiles = encoder.layout.tiles
    let encoded = Mutex(0)
    let finished = AsyncStream<Void>.makeStream()
    let pending = Mutex(tiles.count)
    encoder.onOutput { output in
      if case .tile = output { encoded.withLock { $0 += 1 } }
      let left = pending.withLock { state in
        state -= 1
        return state
      }
      if left == 0 { finished.continuation.finish() }
    }
    try encoder.encode(
      ScreenSharingTileEncodeRequest(
        pixelBuffer: try picture(width: width, height: height), sourceTimestampNs: 1, capturedNs: 0,
        update: ScreenSharingTileUpdate(id: 1, tiles: tiles)))
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { for await _ in finished.stream {} }
      group.addTask { try await Task.sleep(for: timeout) }
      try await group.next()
      group.cancelAll()
    }
    return encoded.withLock { $0 }
  }

  private static func picture(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw BenchUsageError(message: "no pixel buffer (\(status))") }

    return buffer
  }
}
