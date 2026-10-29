public struct BenchInterfaceRate: Sendable, Equatable {
  private static let megabitsPerBytePerNs = 8_000.0

  public let receivedMbps: Double
  public let sentMbps: Double

  public init?(from earlier: BenchInterfaceCounters, to later: BenchInterfaceCounters) {
    let elapsedNs = Double(later.sampledNs - earlier.sampledNs)
    guard elapsedNs > 0 else { return nil }

    receivedMbps = Double(later.receivedBytes &- earlier.receivedBytes) / elapsedNs * Self.megabitsPerBytePerNs
    sentMbps = Double(later.sentBytes &- earlier.sentBytes) / elapsedNs * Self.megabitsPerBytePerNs
  }
}
