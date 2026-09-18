import ScreenSharing

extension ScreenSharingDiagnosticProfile {
  /// The process-wide trial selection this profile requires.
  public var trialSelection: ScreenSharingFieldTrials.Selection {
    .init(name: name, trials: fieldTrials)
  }
}
