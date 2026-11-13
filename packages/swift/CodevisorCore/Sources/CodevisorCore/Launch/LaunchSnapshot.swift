import CodevisorClient

public struct LaunchSnapshot: Equatable, Sendable {
  public var localDataFailure: String?
  public var hasLocalData: Bool
  public var serverState: LocalCodevisorServerState?
  public var dataUpgrade: LocalDataUpgradeProgress?
  public var availability: ServerAvailability
  public var isWaitingForGit: Bool
  public var startIsSlow: Bool

  public init(
    localDataFailure: String? = nil,
    hasLocalData: Bool,
    serverState: LocalCodevisorServerState? = nil,
    dataUpgrade: LocalDataUpgradeProgress? = nil,
    availability: ServerAvailability = .waiting(.connecting),
    isWaitingForGit: Bool = false,
    startIsSlow: Bool = false
  ) {
    self.localDataFailure = localDataFailure
    self.hasLocalData = hasLocalData
    self.serverState = serverState
    self.dataUpgrade = dataUpgrade
    self.availability = availability
    self.isWaitingForGit = isWaitingForGit
    self.startIsSlow = startIsSlow
  }
}
