struct ScreenSharingEncoderPresentationClock {
  enum Gap {
    case standard
    case content(Int64)
    case wallClock
  }

  static let longestGapFrames: Int64 = 2

  private let shortestGapNs: Int64
  private let frameNs: Int64
  private let longestGapNs: Int64
  private var lastPresentationNs: Int64?
  private var lastSubmittedNs: Int64 = 0

  init(framesPerSecond: Int, shortestGapNs: Int64 = 1) {
    self.shortestGapNs = shortestGapNs
    frameNs = max(shortestGapNs, 1_000_000_000 / Int64(max(1, framesPerSecond)))
    longestGapNs = max(shortestGapNs, Self.longestGapFrames * 1_000_000_000 / Int64(max(1, framesPerSecond)))
  }

  mutating func presentationNs(submittedAtNs submittedNs: Int64, gap: Gap = .standard) -> Int64 {
    let longestNs = longestNs(gap)
    let presentationNs = lastPresentationNs.map { $0 + gapNs(to: submittedNs, longestNs: longestNs) } ?? submittedNs
    lastPresentationNs = presentationNs
    lastSubmittedNs = submittedNs
    return presentationNs
  }

  private func longestNs(_ gap: Gap) -> Int64 {
    switch gap {
    case .standard: longestGapNs
    case .content(let intervalNs): min(longestGapNs, max(frameNs, intervalNs))
    case .wallClock: .max
    }
  }

  private func gapNs(to submittedNs: Int64, longestNs: Int64) -> Int64 {
    min(longestNs, max(shortestGapNs, submittedNs - lastSubmittedNs))
  }
}
