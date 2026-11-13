import CodevisorClient

public enum LaunchPhase: Equatable, Sendable {
  case starting
  case startingSlowly
  case updatingData(LocalDataUpgradeProgress)
  case failed(LaunchFailure)
  case ready
}
