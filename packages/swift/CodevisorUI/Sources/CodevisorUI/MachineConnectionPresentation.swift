import CodevisorCore

/// Client reachability and sync results take precedence over cloud presence.
/// An online cloud host does not prove this client can use that machine.
public enum MachineConnectionPresentation: Equatable {
  case checking
  case waiting(ServerWaitingReason)
  case offline
  case syncing
  case online(isDirect: Bool)

  public init(
    status: MachineStatus?,
    availability: ServerAvailability?,
    navigationSyncState: NavigationSyncState?,
    cloudOnline: Bool?,
    usesDirectConnection: Bool
  ) {
    if case let .waiting(reason) = availability {
      if reason == .connecting {
        // Automatic reconnects retain Offline until the failure clears.
        if case .stale = navigationSyncState {
          self = .offline
          return
        }
        if status?.isReachable == false {
          self = .offline
          return
        }
      }
      self = .waiting(reason)
    } else if case .failed = availability {
      self = .offline
    } else if let status, !status.isReachable {
      self = .offline
    } else if case .stale = navigationSyncState {
      self = .offline
    } else if status?.isReachable == true {
      self = navigationSyncState == .current ? .online(isDirect: usesDirectConnection) : .syncing
    } else {
      self = cloudOnline == false ? .offline : .checking
    }
  }

  public var label: String {
    switch self {
    case .checking: "Checking…"
    case .waiting(.starting): "Starting…"
    case .waiting(.connecting): "Connecting…"
    case .waiting(.updating): "Updating…"
    case .waiting(.restarting): "Restarting…"
    case .offline: "Offline"
    case .syncing: "Syncing…"
    case .online(let isDirect): isDirect ? "Online · Direct" : "Online"
    }
  }

}
