import CoreMedia
import CoreVideo
import Foundation

public enum ScreenSharingVideoCodec: String, Sendable, CaseIterable {
  case h264
  case hevc
  case hevc444

  package var mediaType: CMVideoCodecType { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }
  package var payloadName: String { self == .h264 ? "H264" : "H265" }
  var decodedPixelFormat: OSType { decodedPixelFormat(.standard) }
  func decodedPixelFormat(_ range: ScreenSharingDynamicRange) -> OSType {
    switch (self == .hevc444, range) {
    case (true, .standard): kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
    case (false, .standard): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    case (true, .high): kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
    case (false, .high): kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
  }
  public var capturePixelFormat: OSType {
    self == .hevc444 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  }
  public var supportsHighDynamicRange: Bool { self == .hevc444 }
  package var sdpParameters: [String: String] {
    if self == .h264 {
      return ["profile-level-id": "42e034", "packetization-mode": "1", "level-asymmetry-allowed": "1"]
    }
    return ["profile-id": self == .hevc444 ? "4" : "1", "tier-flag": "0", "level-id": "153"]
  }
}

extension ScreenSharingVideoCodec {
  public static func negotiated(inDescription sdp: String) -> ScreenSharingVideoCodec? {
    let lines = sdp.split(whereSeparator: \.isNewline).map(String.init)
    guard let media = lines.first(where: { $0.hasPrefix("m=video") }),
      let payload = media.split(separator: " ").dropFirst(3).first.map(String.init),
      let rtpmap = lines.first(where: { $0.hasPrefix("a=rtpmap:\(payload) ") }),
      let name = rtpmap.split(separator: " ").last?.split(separator: "/").first
    else { return nil }
    switch name.uppercased() {
    case "H264": return .h264
    case "H265":
      let fmtp = lines.first { $0.hasPrefix("a=fmtp:\(payload) ") } ?? ""
      let profile = fmtp.split(separator: " ").dropFirst().joined(separator: " ").split(separator: ";")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix("profile-id=") }?.dropFirst("profile-id=".count)
      return profile == "4" ? .hevc444 : .hevc
    default: return nil
    }
  }
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

  var dynamicRange: ScreenSharingDynamicRange? {
    guard lumaDepth == chromaDepth else { return nil }
    return lumaDepth == 8 ? .standard : lumaDepth == 10 ? .high : nil
  }

  var codec: ScreenSharingVideoCodec? {
    guard let dynamicRange else { return nil }
    if chroma == 1, profile == (dynamicRange == .high ? 2 : 1) { return .hevc }
    if profile == 4, chroma == 3 { return .hevc444 }
    return nil
  }

  func validate(for codec: ScreenSharingVideoCodec) throws {
    guard codec != .h264, self.codec == codec else {
      throw ScreenSharingError.invalid("HEVC output does not match the negotiated profile, chroma or bit depth.")
    }
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
