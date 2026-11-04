struct ScreenSharingV2RefreshPhase {
  let periodNs: Int64
  let offsetNs: Int64
  private var anchorNs: Int64?

  init(
    periodNs: Int64 = 1_000_000_000 / Int64(ScreenSharingV2Profile.framesPerSecond),
    offsetNs: Int64 = ScreenSharingV2Profile.refinementRefreshOffsetNs
  ) {
    self.periodNs = periodNs
    self.offsetNs = offsetNs
  }

  mutating func observe(frameAtNs: Int64) {
    anchorNs = frameAtNs
  }

  func aligned(_ dueNs: Int64) -> Int64 {
    guard let anchorNs else { return dueNs }

    let phase = (dueNs - anchorNs - offsetNs) % periodNs
    let positive = phase < 0 ? phase + periodNs : phase
    return positive == 0 ? dueNs : dueNs + periodNs - positive
  }
}
