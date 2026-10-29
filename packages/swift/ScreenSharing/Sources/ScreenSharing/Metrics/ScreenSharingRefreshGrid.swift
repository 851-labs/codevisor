struct ScreenSharingRefreshGrid: Equatable, Sendable {
  let targetNs: Int64
  let periodNs: Int64

  func onGlass(afterGPUCompletionAt completedNs: Int64) -> Int64? {
    firstRefresh(atOrAfter: completedNs).map { $0 + periodNs }
  }

  func firstRefresh(atOrAfter timeNs: Int64) -> Int64? {
    guard periodNs > 0 else { return nil }

    return targetNs + Self.ceilingDivision(timeNs - targetNs, by: periodNs) * periodNs
  }

  private static func ceilingDivision(_ value: Int64, by divisor: Int64) -> Int64 {
    let quotient = value / divisor
    return value % divisor > 0 ? quotient + 1 : quotient
  }
}
