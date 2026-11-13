import Foundation

public struct ServerPluginEventSubscription: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var sessionId: String
  public var plugin: String
  public var pluginName: String
  public var symbolName: String?
  public var accountId: String?
  public var event: String
  public var eventTitle: String?
  public var label: String?
  public var firesAt: String?
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
    symbolName: String? = nil,
    event: String,
    eventTitle: String? = nil,
    label: String? = nil,
    firesAt: String? = nil,
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
    self.symbolName = symbolName
    self.event = event
    self.eventTitle = eventTitle
    self.label = label
    self.firesAt = firesAt
    self.explained = explained
    self.note = note
    self.once = once
    self.createdBy = createdBy
    self.pausedReason = pausedReason
    self.createdAt = createdAt
  }
}
