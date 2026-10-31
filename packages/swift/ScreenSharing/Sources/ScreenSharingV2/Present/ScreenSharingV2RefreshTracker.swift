struct ScreenSharingV2RefreshTracker {
  private var previousTargetNs: Int64?

  mutating func period(atTargetNs targetNs: Int64) -> Int64? {
    defer { previousTargetNs = targetNs }
    guard let previousTargetNs, targetNs > previousTargetNs else { return nil }

    return targetNs - previousTargetNs
  }
}
