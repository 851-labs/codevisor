import CodevisorClient

public struct LaunchGate: Equatable, Sendable {
  public private(set) var hasOpened = false
  private var dismissed: LaunchFailure?

  public init() {}

  public func phase(for snapshot: LaunchSnapshot) -> LaunchPhase {
    if let message = snapshot.localDataFailure {
      return .failed(LaunchFailure(stage: .localData, message: message))
    }
    if let upgrade = snapshot.dataUpgrade {
      return upgradePhase(upgrade)
    }
    if hasOpened { return .ready }

    return startupPhase(snapshot)
  }

  public mutating func note(_ phase: LaunchPhase) {
    if phase == .ready { hasOpened = true }
  }

  public mutating func continueAnyway(past failure: LaunchFailure) {
    guard failure.canContinue else { return }

    hasOpened = true
    dismissed = failure
  }

  private func upgradePhase(_ upgrade: LocalDataUpgradeProgress) -> LaunchPhase {
    guard upgrade.state == "failed" else { return .updatingData(upgrade) }

    let failure = LaunchFailure(stage: .dataUpgrade, message: upgradeError(upgrade))
    return failure == dismissed ? .ready : .failed(failure)
  }

  private func startupPhase(_ snapshot: LaunchSnapshot) -> LaunchPhase {
    if case let .unavailable(message) = snapshot.serverState {
      return .failed(LaunchFailure(stage: .server, message: message))
    }
    guard snapshot.hasLocalData else { return .starting }

    switch snapshot.availability {
    case .ready: return .ready
    case let .failed(message): return .failed(LaunchFailure(stage: .server, message: message))
    case .waiting: return waitingPhase(snapshot)
    }
  }

  private func waitingPhase(_ snapshot: LaunchSnapshot) -> LaunchPhase {
    guard snapshot.startIsSlow, !snapshot.isWaitingForGit else { return .starting }

    return .startingSlowly
  }

  private func upgradeError(_ upgrade: LocalDataUpgradeProgress) -> String {
    upgrade.error ?? "\(upgrade.name) didn't finish."
  }
}
