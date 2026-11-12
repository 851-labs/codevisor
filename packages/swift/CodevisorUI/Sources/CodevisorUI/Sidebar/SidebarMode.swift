public enum SidebarMode: String, CaseIterable, Codable, Sendable {
  case bots = "chat"
  case code

  public static let preferenceKey = "sidebar.mode"

  public var title: String {
    switch self {
    case .bots: "Bots"
    case .code: "Code"
    }
  }
}
