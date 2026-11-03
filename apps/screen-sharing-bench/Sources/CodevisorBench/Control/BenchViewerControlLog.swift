struct BenchViewerControlLog {
  var grantedAfterMs: Double?
  var denial: String?
  var losses: [String] = []
  var forwardedEvents = 0
  var inputReleases = 0
  var forwarded: [BenchInputStamp] = []

  var answered: Bool {
    grantedAfterMs != nil || denial != nil
  }

  func summary(capturesSystemShortcuts: Bool) -> BenchViewerControlSummary {
    BenchViewerControlSummary(
      granted: grantedAfterMs != nil, grantedAfterMs: grantedAfterMs, denial: denial, losses: losses,
      forwardedEvents: forwardedEvents, inputReleases: inputReleases, capturesSystemShortcuts: capturesSystemShortcuts,
      forwarded: forwarded)
  }
}
