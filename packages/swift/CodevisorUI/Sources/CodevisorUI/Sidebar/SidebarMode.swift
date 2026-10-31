public enum SidebarMode: String, CaseIterable, Codable, Sendable {
  case chat
  case code

  public static let preferenceKey = "sidebar.mode"

  public static func active(_ stored: SidebarMode, botsEnabled: Bool) -> SidebarMode {
    botsEnabled ? stored : .code
  }

  public var title: String {
    switch self {
    case .chat: "Chat"
    case .code: "Code"
    }
  }
}
