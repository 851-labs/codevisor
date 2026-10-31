import CodevisorCore

public enum ServerAvailabilityFallbackPolicy {
  public static func offersLocalMachine(
    isLocal: Bool,
    availability: ServerAvailability,
    appUpdateInProgress: Bool = false
  ) -> Bool {
    guard !isLocal, !appUpdateInProgress else {
      return false
    }
    switch availability {
    case .waiting(.starting), .waiting(.connecting), .failed:
      return true
    case .waiting(.updating), .waiting(.restarting), .ready:
      return false
    }
  }
}
