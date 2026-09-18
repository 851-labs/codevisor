import ScreenSharing
extension ScreenSharingPeer {
  /// Pins the process trial selection and publishes what is ACTUALLY installed. Separated from `init` so the
  /// ordering contract (trials pinned strictly before any RTC object exists) can be exercised over a controlled
  /// factory boundary in tests without a fake initializer ever reaching a real factory.
  @discardableResult
  static func bootstrapTrials(
    _ trials: ScreenSharingFieldTrials = .process, publishingInto metrics: ScreenSharingMetrics
  ) -> ScreenSharingFieldTrials.Selection {
    let installed = trials.ensureInstalled()
    // Published from the ACTUAL installed map, never from a caller's request: absence stays absence.
    if let playout = installed.playoutExperimentLabel { metrics.label("playoutExperiment", playout) }
    // Provenance of the FIRST installer, which after semantic idempotence need not name this caller's profile.
    metrics.label("fieldTrialProvenance", installed.name)
    return installed
  }

}
