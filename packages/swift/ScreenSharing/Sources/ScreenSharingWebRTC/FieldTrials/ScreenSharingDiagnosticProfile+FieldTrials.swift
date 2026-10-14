import ScreenSharing

extension ScreenSharingDiagnosticProfile {
  public var trialSelection: ScreenSharingFieldTrials.Selection {
    .init(name: name, trials: fieldTrials)
  }
}
