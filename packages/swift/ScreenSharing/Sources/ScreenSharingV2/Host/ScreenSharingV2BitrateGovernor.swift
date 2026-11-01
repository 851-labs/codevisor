struct ScreenSharingV2BitrateGovernor {
  private static let intervalNs: Int64 = 250_000_000
  private static let threshold = 0.1

  private(set) var applied: Int
  private var checkedNs: Int64 = 0

  init(initial: Int) {
    applied = initial
  }

  mutating func update(ceilingKbps: UInt64, atNs nowNs: Int64) -> Int? {
    guard nowNs - checkedNs >= Self.intervalNs else { return nil }

    checkedNs = nowNs
    let target = ScreenSharingV2Profile.encoderBitrate(ceilingKbps: ceilingKbps)
    guard changesEnough(target) else { return nil }

    applied = target
    return target
  }

  private func changesEnough(_ target: Int) -> Bool {
    abs(Double(target - applied)) > Double(applied) * Self.threshold
  }
}
