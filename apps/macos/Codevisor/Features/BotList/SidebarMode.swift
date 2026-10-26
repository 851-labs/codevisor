import CodevisorCore

enum SidebarMode: String, CaseIterable, Codable {
  case chat
  case code

  static let preferenceKey = "sidebar.mode"

  static func active(_ stored: SidebarMode, botsEnabled: Bool) -> SidebarMode {
    botsEnabled ? stored : .code
  }

  static func owning(_ selection: SidebarSelection) -> SidebarMode? {
    switch selection {
    case .bot: .chat
    case .session, .workspace, .archivedWorkspace: .code
    case .newChat: nil
    }
  }

  var title: String {
    switch self {
    case .chat: "Chat"
    case .code: "Code"
    }
  }

  var defaultSelection: SidebarSelection? {
    switch self {
    case .chat: nil
    case .code: .newChat(nil)
    }
  }
}
