public struct BenchCalibration: Codable, Sendable, Equatable {
  public struct ObserverInterference: Codable, Sendable, Equatable {
    public var fpsDeltaPct: Double
    public var cpuDeltaPct: Double

    public init(fpsDeltaPct: Double, cpuDeltaPct: Double) {
      self.fpsDeltaPct = fpsDeltaPct
      self.cpuDeltaPct = cpuDeltaPct
    }
  }

  public var observerAgreementMs: BenchDistribution?
  public var nullSharingImageAgeMs: BenchDistribution?
  public var localI2pMs: BenchDistribution?
  public var observerInterference: ObserverInterference?

  public init(
    observerAgreementMs: BenchDistribution? = nil, nullSharingImageAgeMs: BenchDistribution? = nil,
    localI2pMs: BenchDistribution? = nil, observerInterference: ObserverInterference? = nil
  ) {
    self.observerAgreementMs = observerAgreementMs
    self.nullSharingImageAgeMs = nullSharingImageAgeMs
    self.localI2pMs = localI2pMs
    self.observerInterference = observerInterference
  }
}
