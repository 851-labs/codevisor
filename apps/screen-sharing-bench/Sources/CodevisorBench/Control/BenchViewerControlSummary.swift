struct BenchViewerControlSummary: Encodable {
  let granted: Bool
  let grantedAfterMs: Double?
  let denial: String?
  let losses: [String]
  let forwardedEvents: Int
  let inputReleases: Int
  let capturesSystemShortcuts: Bool
  let forwarded: [BenchInputStamp]
  let clickProbe: BenchClickProbe.Summary
}
