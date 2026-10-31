import CoreVideo
import ScreenSharingWebRTC

struct EncodeLabConfig: Sendable, Codable, Equatable {
  var name = "product"
  var engine = EncodeLabEngine.videoToolbox
  var codec = EncodeLabCodec.hevc444
  var rateControl = EncodeLabRateControl.standard
  var prioritizeSpeed = true
  var megabitsPerSecond: Double? = Double(ScreenSharingProductProfile.bitrateCeiling) / 1_000_000
  var width = Int(ScreenSharingProductProfile.captureBox.width)
  var height = Int(ScreenSharingProductProfile.captureBox.height)
  var tiles = 1
  var skipCleanTiles = false
  var longTermReferences = false
  var maxFrameDelay: Int?
  var maxQP: Int?
  var minQP: Int?
  var rateLimit: EncodeLabRateLimit?
  var preset: String?
  var constantQuality: Double?
  var spatialAdaptiveQP: Bool?
  var feedsYCbCr: Bool?
  var ackMilliseconds = 33
  var vcpInput = "444f"
  var refinements = 0

  var tileHeight: Int { height / tiles }
  var sessionBitsPerSecond: Int? { megabitsPerSecond.map { Int($0 * 1_000_000) / sessionTiles } }
  var sessionRateLimitBytes: Int? { rateLimit.map { $0.bytesPerWindow / sessionTiles } }

  func encodedTiles(dirty: Set<Int>, forced: Set<Int>) -> Set<Int> {
    guard engine == .videoToolbox, skipCleanTiles else { return Set(0..<sessionTiles) }

    return dirty.union(forced)
  }

  var comparesInFullRange: Bool {
    engine == .videoProcessing && vcpInputFormat == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
  }

  var referenceFormat: OSType {
    comparesInFullRange
      ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
  }

  var decodedFormat: OSType {
    guard codec == .hevc444 else { return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }

    return referenceFormat
  }

  var vcpInputFormat: OSType { vcpInput.utf8.reduce(0) { $0 << 8 | OSType($1) } }
  var ackRoundTripNs: Int64 { Int64(ackMilliseconds) * 1_000_000 }
  var sessionTiles: Int { engine == .videoToolbox ? tiles : 1 }
  var refreshKind: EncodeLabRefresh {
    longTermReferences || engine == .videoProcessing ? .longTermReference : .keyframe
  }
  var inputIsYCbCr: Bool { feedsYCbCr ?? (codec != .hevc444) }
}
