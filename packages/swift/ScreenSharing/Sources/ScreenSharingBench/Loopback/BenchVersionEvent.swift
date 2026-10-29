public struct BenchVersionEvent: Codable, Sendable, Equatable {
  public let version: Int
  public let ns: Int64

  public init(version: Int, ns: Int64) {
    self.version = version
    self.ns = ns
  }
}
