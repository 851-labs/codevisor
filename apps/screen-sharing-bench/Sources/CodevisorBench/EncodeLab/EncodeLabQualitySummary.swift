struct EncodeLabQualitySummary: Codable, Sendable {
  let samples: Int
  let psnrYMean: Double
  let psnrYMin: Double
  let psnrCbCrMean: Double
  let ssimYMean: Double
  let ssimYMin: Double
  let refreshPsnrY: Double?
  let nativePsnrYMean: Double?
  let nativeSsimYMean: Double?

  init?(_ samples: [EncodeLabQualitySample], atNativeSize: Bool) {
    guard !samples.isEmpty else { return nil }

    self.samples = samples.count
    psnrYMean = Self.mean(samples.map(\.psnrY))
    psnrYMin = samples.map(\.psnrY).min() ?? 0
    psnrCbCrMean = Self.mean(samples.map(\.psnrCbCr))
    ssimYMean = Self.mean(samples.map(\.ssimY))
    ssimYMin = samples.map(\.ssimY).min() ?? 0
    refreshPsnrY = samples.first(where: \.refresh)?.psnrY
    let native = Self.native(samples, atNativeSize: atNativeSize)
    nativePsnrYMean = native.map { Self.mean($0.map(\.psnrY)) }
    nativeSsimYMean = native.map { Self.mean($0.map(\.ssimY)) }
  }

  private static func native(_ samples: [EncodeLabQualitySample], atNativeSize: Bool) -> [EncodeLabNativeQuality]? {
    guard !atNativeSize else { return samples.map { EncodeLabNativeQuality(psnrY: $0.psnrY, ssimY: $0.ssimY) } }

    let native = samples.compactMap(\.native)
    return native.isEmpty ? nil : native
  }

  private static func mean(_ values: [Double]) -> Double {
    values.reduce(0, +) / Double(values.count)
  }
}
