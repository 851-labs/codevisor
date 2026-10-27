import Foundation

public struct ServerPluginEventSubscription: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var sessionId: String
  public var plugin: String
  public var pluginName: String
  public var accountId: String?
  public var event: String
  public var filter: String?
  public var explained: String
  public var note: String?
  public var once: Bool
  public var createdBy: String
  public var pausedReason: String?
  public var createdAt: String

  public init(
    id: String,
    sessionId: String,
    plugin: String,
    pluginName: String,
    event: String,
    explained: String,
    note: String? = nil,
    once: Bool = false,
    createdBy: String = "agent",
    pausedReason: String? = nil,
    createdAt: String = ""
  ) {
    self.id = id
    self.sessionId = sessionId
    self.plugin = plugin
    self.pluginName = pluginName
    self.event = event
    self.explained = explained
    self.note = note
    self.once = once
    self.createdBy = createdBy
    self.pausedReason = pausedReason
    self.createdAt = createdAt
  }
}
