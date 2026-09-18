import CoreMedia
import CoreVideo
import Foundation

/// H.264 remains the product default. HEVC variants are explicit diagnostic
/// choices until transport recovery and hardware compatibility are validated.
public enum ScreenSharingVideoCodec: String, Sendable, CaseIterable {
  case h264
  case hevc
  case hevc444

  var mediaType: CMVideoCodecType { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }
  package var payloadName: String { self == .h264 ? "H264" : "H265" }
  var decodedPixelFormat: OSType {
    self == .hevc444 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  }
  /// BGRA preserves all source chroma for the hardware Main444 encoder.
  public var capturePixelFormat: OSType {
    self == .hevc444 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  }
  package var sdpParameters: [String: String] {
    if self == .h264 {
      return ["profile-level-id": "42e034", "packetization-mode": "1", "level-asymmetry-allowed": "1"]
    }
    return ["profile-id": self == .hevc444 ? "4" : "1", "tier-flag": "0", "level-id": "153"]
  }
}

/// Parse the hvcC fields needed to reject silent chroma/depth fallback.
struct ScreenSharingHEVCFormat: Equatable {
  let profile: Int
  let chroma: Int
  let lumaDepth: Int
  let chromaDepth: Int

  init(configuration: Data) throws {
    let bytes = [UInt8](configuration)
    guard bytes.count >= 23, bytes[0] == 1 else {
      throw ScreenSharingError.invalid("Invalid HEVC decoder configuration.")
    }
    profile = Int(bytes[1] & 31)
    chroma = Int(bytes[16] & 3)
    lumaDepth = 8 + Int(bytes[17] & 7)
    chromaDepth = 8 + Int(bytes[18] & 7)
  }

  func validate(for codec: ScreenSharingVideoCodec) throws {
    guard codec != .h264, profile == (codec == .hevc444 ? 4 : 1),
      chroma == (codec == .hevc444 ? 3 : 1), lumaDepth == 8, chromaDepth == 8
    else { throw ScreenSharingError.invalid("HEVC output does not match the negotiated profile, chroma or bit depth.") }
  }

  static func read(_ description: CMFormatDescription) throws -> Self {
    let atoms =
      CMFormatDescriptionGetExtension(
        description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
    guard let data = atoms?["hvcC"] as? Data else {
      throw ScreenSharingError.invalid("Missing HEVC decoder configuration.")
    }
    return try Self(configuration: data)
  }
}
