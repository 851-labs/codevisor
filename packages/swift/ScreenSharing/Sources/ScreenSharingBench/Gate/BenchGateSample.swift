public struct BenchGateSample: Sendable, Equatable {
  public var e2eP50Ms: Double
  public var e2eP95Ms: Double
  public var updatesPerS: Double
  public var freezeRatio: Double?
  public var psnrY: Double?
  public var errors: Int

  public init(
    e2eP50Ms: Double, e2eP95Ms: Double, updatesPerS: Double, freezeRatio: Double? = nil, psnrY: Double? = nil,
    errors: Int = 0
  ) {
    self.e2eP50Ms = e2eP50Ms
    self.e2eP95Ms = e2eP95Ms
    self.updatesPerS = updatesPerS
    self.freezeRatio = freezeRatio
    self.psnrY = psnrY
    self.errors = errors
  }
}
