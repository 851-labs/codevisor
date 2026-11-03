struct ScreenSharingVCPSubmission: Sendable {
  let id: UInt64
  let update: ScreenSharingTileUpdate
  let sourceTimestampNs: Int64
  let capturedNs: Int64
  let refresh: ScreenSharingTileRefresh?
  let submittedNs: Int64
  let presentationNs: Int64
}
