import Foundation

public enum PaneKind: String, Codable, Sendable {
  case terminal
  case chat
  case newTab
  case plugin
  case document
  case browser
  case screenSharing
  case subagent
  case review
  case simulator
  case transcript

  public var isDeviceLocal: Bool { self == .newTab || self == .subagent || self == .transcript }
}

public struct PaneDescriptorState: Identifiable, Codable, Sendable, Equatable {
  public let id: UUID
  public let kind: PaneKind
  public var name: String
  public let terminalKey: String
  public var chatSessionId: UUID?
  public var ownerChatSessionId: UUID?
  public var pluginId: String?
  public var pluginPaneType: String?
  public var screenSharing: ScreenSharingPanePreferences?
  public var browserURL: String?
  public var documentPath: String?
  public var review: ReviewPanePreferences?
  public var simulator: SimulatorPanePreferences?
  public var liveTitle: String?
  public var terminalActivity: TerminalActivity?
  public var subagentToolCallId: String?
  public init(
    id: UUID,
    kind: PaneKind,
    name: String,
    terminalKey: String,
    chatSessionId: UUID? = nil,
    ownerChatSessionId: UUID? = nil,
    pluginId: String? = nil,
    pluginPaneType: String? = nil,
    documentPath: String? = nil,
    browserURL: String? = nil,
    screenSharing: ScreenSharingPanePreferences? = nil,
    review: ReviewPanePreferences? = nil,
    simulator: SimulatorPanePreferences? = nil,
    liveTitle: String? = nil,
    terminalActivity: TerminalActivity? = nil,
    subagentToolCallId: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.terminalKey = terminalKey
    self.chatSessionId = chatSessionId
    self.ownerChatSessionId = ownerChatSessionId
    self.pluginId = pluginId
    self.pluginPaneType = pluginPaneType
    self.documentPath = documentPath
    self.browserURL = browserURL
    self.screenSharing = screenSharing
    self.review = review
    self.simulator = simulator
    self.liveTitle = liveTitle
    self.terminalActivity = terminalActivity
    self.subagentToolCallId = subagentToolCallId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      kind: try container.decode(PaneKind.self, forKey: .kind),
      name: try container.decode(String.self, forKey: .name),
      terminalKey: try container.decode(String.self, forKey: .terminalKey),
      chatSessionId: try container.decodeIfPresent(UUID.self, forKey: .chatSessionId),
      ownerChatSessionId: try container.decodeIfPresent(UUID.self, forKey: .ownerChatSessionId),
      pluginId: try container.decodeIfPresent(String.self, forKey: .pluginId),
      pluginPaneType: try container.decodeIfPresent(String.self, forKey: .pluginPaneType),
      documentPath: try container.decodeIfPresent(String.self, forKey: .documentPath),
      browserURL: try container.decodeIfPresent(String.self, forKey: .browserURL),
      screenSharing: try container.decodeIfPresent(ScreenSharingPanePreferences.self, forKey: .screenSharing),
      review: try container.decodeIfPresent(ReviewPanePreferences.self, forKey: .review),
      simulator: try container.decodeIfPresent(SimulatorPanePreferences.self, forKey: .simulator),
      liveTitle: try container.decodeIfPresent(String.self, forKey: .liveTitle),
      terminalActivity: try container.decodeIfPresent(TerminalActivity.self, forKey: .terminalActivity),
      subagentToolCallId: try container.decodeIfPresent(String.self, forKey: .subagentToolCallId)
    )
  }

  public var displayName: String {
    guard kind == .terminal, Self.isDefaultTerminalName(name) else { return name }
    return liveTitle ?? Self.defaultTerminalName
  }

  public static let defaultTerminalName = "Terminal"

  static func normalizedLiveTitle(_ title: String?) -> String? {
    guard let title else { return nil }
    let line = title.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return line.isEmpty ? nil : line
  }

  private static func isDefaultTerminalName(_ name: String) -> Bool {
    guard name.hasPrefix("Terminal") else { return false }
    let suffix = name.dropFirst("Terminal".count)
    return suffix.isEmpty || (suffix.hasPrefix(" ") && Int(suffix.dropFirst()) != nil)
  }

  public var terminalAgentStatus: AgentPaneStatus? {
    guard kind == .terminal else { return nil }
    switch terminalActivity {
    case .working: return .working
    case .done: return .unread
    case .blocked: return .actionRequired
    case .error: return .error
    case .idle, nil: return nil
    }
  }
}

public enum TerminalActivity: String, Codable, Sendable {
  case working
  case idle
  case done
  case blocked
  case error
}

public enum AgentPaneStatus: Sendable, Equatable {
  case working
  case unread
  case actionRequired
  case error
}
