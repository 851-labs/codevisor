public struct BenchDistribution: Codable, Sendable, Equatable {
  public let count: Int
  public let p50: Double
  public let p95: Double
  public let max: Double

  public init?(_ samples: [Double]) {
    guard !samples.isEmpty else { return nil }

    let sorted = samples.sorted()
    count = sorted.count
    p50 = Self.nearestRank(0.5, of: sorted)
    p95 = Self.nearestRank(0.95, of: sorted)
    max = sorted[sorted.count - 1]
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    count = try container.decode(Int.self, forKey: .count)
    p50 = try container.decode(Double.self, forKey: .p50)
    p95 = try container.decode(Double.self, forKey: .p95)
    max = try container.decode(Double.self, forKey: .max)
    guard isOrdered else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "A distribution needs count ≥ 1 and p50 ≤ p95 ≤ max"))
    }
  }

  public static func nearestRank(_ percentile: Double, of sorted: [Double]) -> Double {
    precondition(!sorted.isEmpty && (0...1).contains(percentile), "Nearest rank needs samples and 0 ≤ p ≤ 1")
    let rank = Int((percentile * Double(sorted.count)).rounded(.up))
    return sorted[Swift.max(rank, 1) - 1]
  }

  private var isOrdered: Bool {
    count >= 1 && p50 <= p95 && p95 <= max
  }
}
