struct EncodeLabConfig: Sendable, Codable, Equatable {
  var name = "product"
  var codec = EncodeLabCodec.hevc444
  var rateControl = EncodeLabRateControl.standard
  var prioritizeSpeed: Bool?
  var megabitsPerSecond: Double? = 45
  var width = 2560
  var height = 1440
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

  var tileHeight: Int { height / tiles }
  var tileBitsPerSecond: Int? { megabitsPerSecond.map { Int($0 * 1_000_000) / tiles } }
  var tileRateLimitBytes: Int? { rateLimit.map { $0.bytesPerWindow / tiles } }
  var prioritizesSpeed: Bool { prioritizeSpeed ?? (rateControl == .standard) }
  var inputIsYCbCr: Bool { feedsYCbCr ?? (codec != .hevc444) }
}
