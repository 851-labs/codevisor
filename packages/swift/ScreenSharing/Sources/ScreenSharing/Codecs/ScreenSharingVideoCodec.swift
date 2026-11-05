import CoreMedia
import CoreVideo
import Foundation

public enum ScreenSharingVideoCodec: String, Sendable, CaseIterable {
  case h264
  case hevc
  case hevc444

  package var mediaType: CMVideoCodecType { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }
  public var capturePixelFormat: OSType {
    self == .hevc444 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  }
  public var supportsHighDynamicRange: Bool { self == .hevc444 }
}

public enum ScreenSharingDynamicRange: String, Codable, Sendable, Equatable {
  case standard
  case high

  public static let highCapturePixelFormat = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange

  static let highPixelFormats: Set<OSType> = [
    kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
    kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
  ]

  public init(pixelFormat: OSType) { self = Self.highPixelFormats.contains(pixelFormat) ? .high : .standard }
}

package struct ScreenSharingHEVCFormat: Equatable {
  package let chroma: Int

  init(configuration: Data) throws {
    let bytes = [UInt8](configuration)
    guard bytes.count >= 23, bytes[0] == 1 else {
      throw ScreenSharingError.invalid("Invalid HEVC decoder configuration.")
    }
    chroma = Int(bytes[16] & 3)
  }

  package static func read(_ description: CMFormatDescription) throws -> Self {
    let atoms =
      CMFormatDescriptionGetExtension(
        description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
    guard let data = atoms?["hvcC"] as? Data else {
      throw ScreenSharingError.invalid("Missing HEVC decoder configuration.")
    }
    return try Self(configuration: data)
  }
}
