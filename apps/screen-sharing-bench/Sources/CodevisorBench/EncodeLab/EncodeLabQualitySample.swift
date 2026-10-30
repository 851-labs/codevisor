struct EncodeLabQualitySample: Sendable, Codable {
  let frame: Int
  let version: Int
  let psnrY: Double
  let psnrCbCr: Double
  let ssimY: Double
  let native: EncodeLabNativeQuality?
  let refresh: Bool
}
