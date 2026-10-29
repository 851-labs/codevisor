package struct ScreenSharingFramePresentation: Equatable, Sendable {
  package let receivedAtNs: Int64?
  package let submittedAtNs: Int64
  package let gpuCompletedNs: Int64?
  package let presentedAtNs: Int64?

  package init(receivedAtNs: Int64?, submittedAtNs: Int64, gpuCompletedNs: Int64? = nil, presentedAtNs: Int64?) {
    self.receivedAtNs = receivedAtNs
    self.submittedAtNs = submittedAtNs
    self.gpuCompletedNs = gpuCompletedNs
    self.presentedAtNs = presentedAtNs
  }

  package init(receivedAt: Double?, submittedAt: Double, gpuCompletedAt: Double? = nil, presentedAt: Double) {
    let presented = presentedAt.isFinite && presentedAt > 0 ? presentedAt : nil
    self.init(
      receivedAtNs: receivedAt.map(Self.nanoseconds), submittedAtNs: Self.nanoseconds(submittedAt),
      gpuCompletedNs: gpuCompletedAt.map(Self.nanoseconds), presentedAtNs: presented.map(Self.nanoseconds))
  }

  package static func nanoseconds(_ seconds: Double) -> Int64 { Int64((seconds * 1_000_000_000).rounded()) }
}
