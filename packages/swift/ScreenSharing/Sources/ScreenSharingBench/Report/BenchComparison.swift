public struct BenchComparison: Codable, Sendable, Equatable {
  public enum Verdict: String, Codable, Sendable {
    case codevisorFaster = "codevisor-faster"
    case noDifference = "no-difference"
    case appleFaster = "apple-faster"
  }

  public var scene: String
  public var resolution: String
  public var network: String
  public var metric: String
  public var system: BenchSystem?
  public var appleHp: [Double]
  public var codevisor: [Double]
  public var noiseBandMs: Double
  public var verdict: Verdict

  public init(
    scene: String, resolution: String, network: String, metric: String, system: BenchSystem? = nil,
    appleHp: [Double], codevisor: [Double], noiseBandMs: Double, verdict: Verdict
  ) {
    self.scene = scene
    self.resolution = resolution
    self.network = network
    self.metric = metric
    self.system = system
    self.appleHp = appleHp
    self.codevisor = codevisor
    self.noiseBandMs = noiseBandMs
    self.verdict = verdict
  }

  var validationIssues: [String] {
    var issues: [String] = []
    if appleHp.isEmpty || codevisor.isEmpty { issues.append("needs at least one repetition of each system") }
    if noiseBandMs < 0 { issues.append("noise_band_ms \(noiseBandMs) is negative") }
    if system == .appleHP { issues.append("system must be a Codevisor system, not apple-hp") }
    return issues
  }
}
