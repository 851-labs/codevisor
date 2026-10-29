public struct BenchGateSample: Sendable, Equatable {
  public static let freezeGatedNetworks: Set<String> = ["N3"]
  public static let jitterBufferSplitNetworks: Set<String> = ["N0"]

  public var e2eP50Ms: Double?
  public var e2eP95Ms: Double?
  public var e2eOutsideJitterBufferP50Ms: Double?
  public var e2eOutsideJitterBufferP95Ms: Double?
  public var jitterBufferP50Ms: Double?
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
    guard Self.jitterBufferSplitNetworks.contains(summary.cell.network) else { return }

    e2eOutsideJitterBufferP50Ms = summary.e2eOutsideJitterBufferP50Ms
    e2eOutsideJitterBufferP95Ms = summary.e2eOutsideJitterBufferP95Ms
    jitterBufferP50Ms = summary.stagesP50Ms.decodeQueue
  }

  var isSplitAtTheJitterBuffer: Bool {
    e2eOutsideJitterBufferP50Ms != nil && e2eOutsideJitterBufferP95Ms != nil && jitterBufferP50Ms != nil
  }
}
