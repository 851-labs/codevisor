public enum ServerUpdateStage: Int, CaseIterable, Comparable, Sendable {
  case pausingChats
  case installing
  case updatingData
  case restarting
  case reconnecting

  public var title: String {
    switch self {
    case .pausingChats: "Pausing chats"
    case .installing: "Installing the update"
    case .updatingData: "Updating server data"
    case .restarting: "Restarting the server"
    case .reconnecting: "Reconnecting"
    }
  }

  public static func < (left: Self, right: Self) -> Bool {
    left.rawValue < right.rawValue
  }
}
