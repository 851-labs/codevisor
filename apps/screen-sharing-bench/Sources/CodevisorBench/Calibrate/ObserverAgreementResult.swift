import ScreenSharingBench

struct ObserverAgreementResult: Encodable {
  static let maximumP95Ms = 1_000.0 / 60

  let check = "c1"
  let sources: [String]
  let absoluteDeltaMs: BenchDistribution?
  let sharedVersions: Int
  let unmatchedVersions: Int
  let frames: [Int]
  let unreadableFraction: [Double]
  let passed: Bool

  init(sources: [String], logs: ObserverPair.Logs) {
    let agreement = logs.agreement
    let versions = [BenchObservedVersions(logs.barcode), BenchObservedVersions(logs.full)]
    self.sources = sources
    absoluteDeltaMs = agreement.absoluteDeltaMs
    sharedVersions = agreement.sharedVersions
    unmatchedVersions = agreement.unmatchedVersions
    frames = versions.map(\.frames)
    unreadableFraction = versions.map(\.unreadableFraction)
    passed = agreement.absoluteDeltaMs.map { $0.p95 <= Self.maximumP95Ms } ?? false
  }
}
