struct ScreenSharingEncoderPresentationClock {
  static let longestGapFrames: Int64 = 2

  private let longestGapNs: Int64
  private var lastPresentationNs: Int64?
  private var lastSubmittedNs: Int64 = 0

  init(framesPerSecond: Int) {
    longestGapNs = Self.longestGapFrames * 1_000_000_000 / Int64(max(1, framesPerSecond))
  }

  mutating func presentationNs(submittedAtNs submittedNs: Int64) -> Int64 {
    let presentationNs = lastPresentationNs.map { $0 + gapNs(to: submittedNs) } ?? submittedNs
    lastPresentationNs = presentationNs
    lastSubmittedNs = submittedNs
    return presentationNs
  }

  private func gapNs(to submittedNs: Int64) -> Int64 {
    min(longestGapNs, max(1, submittedNs - lastSubmittedNs))
  }
}
