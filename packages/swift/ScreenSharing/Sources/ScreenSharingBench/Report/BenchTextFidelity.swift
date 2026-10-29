public struct BenchTextFidelity: Codable, Sendable, Equatable {
  public var psnrY: Double
  public var psnrYText: Double
  public var ssimY: Double
  public var psnrCbcr: Double
  public var deltaE00Mean: Double
  public var deltaE00P95: Double
  public var oneToOne: Bool

  public init(
    psnrY: Double, psnrYText: Double, ssimY: Double, psnrCbcr: Double, deltaE00Mean: Double, deltaE00P95: Double,
    oneToOne: Bool
  ) {
    self.psnrY = psnrY
    self.psnrYText = psnrYText
    self.ssimY = ssimY
    self.psnrCbcr = psnrCbcr
    self.deltaE00Mean = deltaE00Mean
    self.deltaE00P95 = deltaE00P95
    self.oneToOne = oneToOne
  }
}
