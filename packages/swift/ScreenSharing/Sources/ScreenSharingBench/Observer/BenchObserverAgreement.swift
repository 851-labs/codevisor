public struct BenchObserverAgreement: Sendable, Equatable {
  public let absoluteDeltaMs: BenchDistribution?
  public let sharedVersions: Int
  public let unmatchedVersions: Int

  public init(_ first: BenchObservedVersions, _ second: BenchObservedVersions) {
    let deltas = second.delaysMs(since: first.firstPtsNs).map(abs)
    absoluteDeltaMs = BenchDistribution(deltas)
    sharedVersions = deltas.count
    unmatchedVersions = Self.missed(by: second, from: first) + Self.missed(by: first, from: second)
  }

  private static func missed(by observer: BenchObservedVersions, from other: BenchObservedVersions) -> Int {
    guard let span = observer.spanNs else { return other.firstPtsNs.count }

    return other.firstPtsNs.count { version, ptsNs in observer.firstPtsNs[version] == nil && span.contains(ptsNs) }
  }
}
