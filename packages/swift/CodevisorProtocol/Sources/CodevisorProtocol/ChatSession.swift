import Foundation

public enum SessionOrigin: String, Sendable, Codable, Equatable {
  case codevisor
  case imported

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    switch value {
    case "codevisor", "herdman": self = .codevisor
    case "imported": self = .imported
    default:
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Unknown session origin: \(value)")
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum SessionSidebarState: String, Sendable, Codable, Equatable {
  case idle
  case inProgress
  case waitingForUser
  case unread
  case errored

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = SessionSidebarState(rawValue: value) ?? .idle
  }
}

public struct ChatSession: Identifiable, Sendable, Codable, Equatable {
  public var id: UUID
  public var projectId: UUID
  public var serverId: String
  public var harnessId: String
  public var harnessAccountId: String?
  public var agentSessionId: String?
  public var title: String
  public var origin: SessionOrigin
  public var worktreeName: String?
  public var cwd: String?
  public var configSelections: [String: String]?
  public var unavailableConfigSelections: [String: String]?
  public var createdAt: Date
  public var updatedAt: Date?
  public var sidebarState: SessionSidebarState
  public var sidebarStateChangedAt: Date
  public var latestAttentionSequence: Int
  public var lastSeenAttentionSequence: Int
  public var unreadCount: Int
  public var hasUnreadError: Bool
  public var actionRequired: Bool
  public var actionRequiredKind: String?
  public var pendingPlanApproval: Bool
  public var latestBotMessage: BotMessagePreview?

  public var hasAgentSession: Bool {
    agentSessionId?.isEmpty == false
  }

  public init(
    id: UUID = UUID(),
    projectId: UUID,
    serverId: String = "local",
    harnessId: String = "",
    harnessAccountId: String? = nil,
    agentSessionId: String? = nil,
    title: String = "New Session",
    origin: SessionOrigin = .codevisor,
    worktreeName: String? = nil,
    cwd: String? = nil,
    configSelections: [String: String]? = nil,
    unavailableConfigSelections: [String: String]? = nil,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    sidebarState: SessionSidebarState = .idle,
    sidebarStateChangedAt: Date? = nil,
    latestAttentionSequence: Int = 0,
    lastSeenAttentionSequence: Int = 0,
    unreadCount: Int = 0,
    hasUnreadError: Bool = false,
    actionRequired: Bool = false,
    actionRequiredKind: String? = nil,
    pendingPlanApproval: Bool = false,
    latestBotMessage: BotMessagePreview? = nil
  ) {
    self.id = id
    self.projectId = projectId
    self.serverId = serverId
    self.harnessId = harnessId
    self.harnessAccountId = harnessAccountId
    self.agentSessionId = agentSessionId
    self.title = title
    self.origin = origin
    self.worktreeName = worktreeName
    self.cwd = cwd
    self.configSelections = configSelections
    self.unavailableConfigSelections = unavailableConfigSelections
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.sidebarState = sidebarState
    self.sidebarStateChangedAt = sidebarStateChangedAt ?? updatedAt ?? createdAt
    self.latestAttentionSequence = latestAttentionSequence
    self.lastSeenAttentionSequence = lastSeenAttentionSequence
    self.unreadCount = unreadCount
    self.hasUnreadError = hasUnreadError
    self.actionRequired = actionRequired
    self.actionRequiredKind = actionRequiredKind
    self.pendingPlanApproval = pendingPlanApproval
    self.latestBotMessage = latestBotMessage
  }

  private enum Keys: String, CodingKey {
    case id, projectId, serverId, harnessId, harnessAccountId, agentSessionId, title, origin
    case worktreeName, cwd, configSelections, unavailableConfigSelections, createdAt, updatedAt
    case sidebarState, sidebarStateChangedAt
    case latestAttentionSequence, lastSeenAttentionSequence, unreadCount, hasUnreadError
    case actionRequired, actionRequiredKind, pendingPlanApproval, latestBotMessage
    case workspaceId
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    id = try container.decode(UUID.self, forKey: .id)
    if let projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId) {
      self.projectId = projectId
    } else {
      projectId = try container.decode(UUID.self, forKey: .workspaceId)
    }
    serverId = try container.decodeIfPresent(String.self, forKey: .serverId) ?? "local"
    harnessId = try container.decodeIfPresent(String.self, forKey: .harnessId) ?? ""
    harnessAccountId = try container.decodeIfPresent(String.self, forKey: .harnessAccountId)
    agentSessionId = try container.decodeIfPresent(String.self, forKey: .agentSessionId)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Session"
    origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin) ?? .codevisor
    worktreeName = try container.decodeIfPresent(String.self, forKey: .worktreeName)
    cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    configSelections = try container.decodeIfPresent([String: String].self, forKey: .configSelections)
    unavailableConfigSelections = try container.decodeIfPresent(
      [String: String].self,
      forKey: .unavailableConfigSelections
    )
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    sidebarState = try container.decodeIfPresent(SessionSidebarState.self, forKey: .sidebarState) ?? .idle
    sidebarStateChangedAt =
      try container.decodeIfPresent(Date.self, forKey: .sidebarStateChangedAt)
      ?? updatedAt
      ?? createdAt
    latestAttentionSequence = try container.decodeIfPresent(Int.self, forKey: .latestAttentionSequence) ?? 0
    lastSeenAttentionSequence = try container.decodeIfPresent(Int.self, forKey: .lastSeenAttentionSequence) ?? 0
    unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
    hasUnreadError = try container.decodeIfPresent(Bool.self, forKey: .hasUnreadError) ?? false
    actionRequired = try container.decodeIfPresent(Bool.self, forKey: .actionRequired) ?? false
    actionRequiredKind = try container.decodeIfPresent(String.self, forKey: .actionRequiredKind)
    pendingPlanApproval = try container.decodeIfPresent(Bool.self, forKey: .pendingPlanApproval) ?? false
    latestBotMessage = try container.decodeIfPresent(BotMessagePreview.self, forKey: .latestBotMessage)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(id, forKey: .id)
    try container.encode(projectId, forKey: .projectId)
    try container.encode(serverId, forKey: .serverId)
    try container.encode(harnessId, forKey: .harnessId)
    try container.encodeIfPresent(harnessAccountId, forKey: .harnessAccountId)
    try container.encodeIfPresent(agentSessionId, forKey: .agentSessionId)
    try container.encode(title, forKey: .title)
    try container.encode(origin, forKey: .origin)
    try container.encodeIfPresent(worktreeName, forKey: .worktreeName)
    try container.encodeIfPresent(cwd, forKey: .cwd)
    try container.encodeIfPresent(configSelections, forKey: .configSelections)
    try container.encodeIfPresent(unavailableConfigSelections, forKey: .unavailableConfigSelections)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    try container.encode(sidebarState, forKey: .sidebarState)
    try container.encode(sidebarStateChangedAt, forKey: .sidebarStateChangedAt)
    try container.encode(latestAttentionSequence, forKey: .latestAttentionSequence)
    try container.encode(lastSeenAttentionSequence, forKey: .lastSeenAttentionSequence)
    try container.encode(unreadCount, forKey: .unreadCount)
    try container.encode(hasUnreadError, forKey: .hasUnreadError)
    try container.encode(actionRequired, forKey: .actionRequired)
    try container.encodeIfPresent(actionRequiredKind, forKey: .actionRequiredKind)
    try container.encode(pendingPlanApproval, forKey: .pendingPlanApproval)
    try container.encodeIfPresent(latestBotMessage, forKey: .latestBotMessage)
  }
}
