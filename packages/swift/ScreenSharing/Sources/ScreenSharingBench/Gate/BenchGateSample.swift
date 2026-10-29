public struct BenchGateSample: Sendable, Equatable {
  public static let freezeGatedNetworks: Set<String> = ["N3"]

  public var e2eP50Ms: Double?
  public var e2eP95Ms: Double?
  public var updatesPerS: Double?
  public var freezeRatio: Double?
  public var psnrY: Double?
  public var errors: Int

  public init(
    e2eP50Ms: Double?, e2eP95Ms: Double?, updatesPerS: Double?, freezeRatio: Double? = nil, psnrY: Double? = nil,
    errors: Int = 0
  ) {
    self.e2eP50Ms = e2eP50Ms
    self.e2eP95Ms = e2eP95Ms
    self.updatesPerS = updatesPerS
    self.freezeRatio = freezeRatio
    self.psnrY = psnrY
    self.errors = errors
  }

  public init(_ summary: BenchCellSummary) {
    let gatesFreezes = Self.freezeGatedNetworks.contains(summary.cell.network)
    self.init(
      e2eP50Ms: summary.e2eP50Ms, e2eP95Ms: summary.e2eP95Ms, updatesPerS: summary.updatesPerS,
      freezeRatio: gatesFreezes ? summary.freezeRatio : nil, psnrY: summary.psnrY, errors: summary.errors)
  }
}
