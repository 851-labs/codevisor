public struct BenchResult: Codable, Sendable, Equatable {
  public struct AboveFloor: Codable, Sendable, Equatable {
    public var p50: Double

    public init(p50: Double) { self.p50 = p50 }
  }

  public struct Bitrate: Codable, Sendable, Equatable {
    public var p50: Double
    public var p95: Double
    public var max: Double
    public var totalMb: Double

    public init(p50: Double, p95: Double, max: Double, totalMb: Double) {
      self.p50 = p50
      self.p95 = p95
      self.max = max
      self.totalMb = totalMb
    }
  }

  public struct ProcessUsage: Codable, Sendable, Equatable {
    public var p50: Double
    public var p95: Double

    public init(p50: Double, p95: Double) {
      self.p50 = p50
      self.p95 = p95
    }
  }

  public struct PerMachine<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var host: Value?
    public var viewer: Value?

    public init(host: Value? = nil, viewer: Value? = nil) {
      self.host = host
      self.viewer = viewer
    }
  }

  public struct Drops: Codable, Sendable, Equatable {
    public var network: Int
    public var jitter: Int
    public var encoder: Int
    public var capture: Int

    public init(network: Int, jitter: Int, encoder: Int, capture: Int) {
      self.network = network
      self.jitter = jitter
      self.encoder = encoder
      self.capture = capture
    }
  }

  public var system: BenchSystem
  public var scene: String
  public var resolution: String
  public var network: String
  public var repetition: Int
  public var seed: UInt64
  public var imageAgeMs: BenchDistribution?
  public var imageAgeAboveFloorMs: AboveFloor?
  public var i2pMs: BenchDistribution?
  public var updatesPerS: Double = 0
  public var shownRatio: Double = 0
  public var skippedVersions = 0
  public var gapMs: BenchDistribution?
  public var judderMs: Double?
  public var freezes: BenchFreezes?
  public var bitrateMbps: Bitrate?
  public var cpuPct: PerMachine<ProcessUsage>?
  public var energyMw: PerMachine<Double>?
  public var text: BenchTextFidelity?
  public var stagesMs: BenchStageTimings?
  public var drops: Drops?
  public var unreadableFraction: Double = 0
  public var valid = true
  public var invalidReason: String?

  public init(system: BenchSystem, scene: String, resolution: String, network: String, repetition: Int, seed: UInt64) {
    self.system = system
    self.scene = scene
    self.resolution = resolution
    self.network = network
    self.repetition = repetition
    self.seed = seed
  }

  private static let largestSeed: UInt64 = (1 << 53) - 1

  var validationIssues: [String] {
    var issues: [String] = []
    if repetition < 1 { issues.append("repetition \(repetition) is below 1") }
    if seed > Self.largestSeed { issues.append("seed \(seed) is above 2^53 − 1, which JSON readers round") }
    if !Self.isFraction(shownRatio) { issues.append("shown_ratio \(shownRatio) is outside 0…1") }
    if let freezes, !Self.isFraction(freezes.ratio) { issues.append("freezes.ratio \(freezes.ratio) is outside 0…1") }
    if !Self.isFraction(unreadableFraction) {
      issues.append("unreadable_fraction \(unreadableFraction) is outside 0…1")
    }
    if valid == (invalidReason != nil) { issues.append("valid must be true exactly when invalid_reason is absent") }
    return issues
  }

  private static func isFraction(_ value: Double) -> Bool {
    (0...1).contains(value)
  }
}
