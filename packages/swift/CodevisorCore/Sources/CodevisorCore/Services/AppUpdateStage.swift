public enum AppUpdateStage: Int, CaseIterable, Comparable, Sendable {
  case downloading
  case preparing
  case stoppingServer
  case restarting

  public var title: String {
    switch self {
    case .downloading: "Downloading the update"
    case .preparing: "Preparing the update"
    case .stoppingServer: "Stopping the server"
    case .restarting: "Installing and restarting"
    }
  }

  public static func < (left: Self, right: Self) -> Bool {
    left.rawValue < right.rawValue
  }
}
