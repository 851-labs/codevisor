public struct BenchInputSchedule: Sendable, Equatable {
  public struct Step: Sendable, Equatable {
    public let kind: BenchInputKind
    public let waitMs: Double
  }

  public static let shortestWaitMs = 150.0
  public static let longestWaitMs = 350.0

  public let steps: [Step]

  public init(keys: Int, clicks: Int, seed: UInt64) {
    var random = SplitMix64(seed: seed)
    let kinds = Self.kinds(keys: keys, clicks: clicks).shuffled(using: &random)
    steps = kinds.map { kind in
      Step(kind: kind, waitMs: Self.shortestWaitMs + random.nextUnitInterval() * Self.waitRangeMs)
    }
  }

  public var totalMs: Double {
    steps.reduce(0) { $0 + $1.waitMs }
  }

  private static let waitRangeMs = longestWaitMs - shortestWaitMs

  private static func kinds(keys: Int, clicks: Int) -> [BenchInputKind] {
    Array(repeating: .key, count: keys) + Array(repeating: .click, count: clicks)
  }
}
