import CoreGraphics
import Foundation
import ImageIO

public struct BotMascotFrames: Sendable {
  private static let fallbackFrameSeconds = 1.0 / 12

  public let images: [CGImage]
  public let frameSeconds: Double

  public func image(at date: Date) -> CGImage? {
    guard !images.isEmpty else { return nil }

    let index = Int(date.timeIntervalSinceReferenceDate / frameSeconds) % images.count
    return images[index]
  }

  @concurrent
  nonisolated static func decode(_ data: Data) async -> BotMascotFrames? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

    let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    let images = (0..<CGImageSourceGetCount(source)).compactMap {
      CGImageSourceCreateImageAtIndex(source, $0, options)
    }
    guard !images.isEmpty else { return nil }
    return BotMascotFrames(images: images, frameSeconds: frameSeconds(of: source))
  }

  private nonisolated static func frameSeconds(of source: CGImageSource) -> Double {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let webP = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
    let delay = webP?[kCGImagePropertyWebPUnclampedDelayTime] as? Double
    return delay.flatMap { $0 > 0 ? $0 : nil } ?? fallbackFrameSeconds
  }
}
