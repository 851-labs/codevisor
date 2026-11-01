public struct BenchTextFidelity: Codable, Sendable, Equatable {
  public static let identicalPSNR = 100.0

  public var psnrY: Double?
  public var psnrYText: Double?
  public var ssimY: Double?
  public var psnrCbcr: Double?
  public var deltaE00Mean: Double?
  public var deltaE00P95: Double?
  public var oneToOne: Bool?

  public init(
    psnrY: Double? = nil, psnrYText: Double? = nil, ssimY: Double? = nil, psnrCbcr: Double? = nil,
    deltaE00Mean: Double? = nil, deltaE00P95: Double? = nil, oneToOne: Bool? = nil
  ) {
    self.psnrY = psnrY.map(Self.reportable)
    self.psnrYText = psnrYText.map(Self.reportable)
    self.ssimY = ssimY
    self.psnrCbcr = psnrCbcr.map(Self.reportable)
    self.deltaE00Mean = deltaE00Mean
    self.deltaE00P95 = deltaE00P95
    self.oneToOne = oneToOne
  }

  public static let notOneToOne = BenchTextFidelity(oneToOne: false)

  private static func reportable(_ psnr: Double) -> Double {
    min(psnr, identicalPSNR)
  }
}
