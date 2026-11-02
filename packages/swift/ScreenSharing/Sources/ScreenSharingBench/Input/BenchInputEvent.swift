public struct BenchInputEvent: Codable, Sendable, Equatable {
  public let kind: BenchInputKind
  public let postedNs: Int64

  public init(kind: BenchInputKind, postedNs: Int64) {
    self.kind = kind
    self.postedNs = postedNs
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case postedNs = "posted_ns"
  }
}
