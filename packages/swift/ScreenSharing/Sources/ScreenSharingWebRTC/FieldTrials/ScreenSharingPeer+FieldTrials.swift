import ScreenSharing
extension ScreenSharingPeer {
  @discardableResult
  nonisolated static func bootstrapTrials(
    _ trials: ScreenSharingFieldTrials = .process, publishingInto metrics: ScreenSharingMetrics
  ) -> ScreenSharingFieldTrials.Selection {
    let installed = trials.ensureInstalled()
    if let playout = installed.playoutExperimentLabel { metrics.label("playoutExperiment", playout) }
    metrics.label("fieldTrialProvenance", installed.name)
    return installed
  }

}
