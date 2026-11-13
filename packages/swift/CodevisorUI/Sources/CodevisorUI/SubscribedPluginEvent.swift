import CodevisorCore
import Foundation

public struct SubscribedPluginEvent: Equatable, Identifiable, Sendable {
  public let id: String
  public let plugin: String
  public let pluginName: String
  public let symbolName: String?
  public let event: String
  public let title: String
  public let firesAt: Date?
  public let note: String?
  public let explained: String

  public var label: String { "\(pluginName) · \(title)" }

  init(_ subscription: ServerPluginEventSubscription) {
    id = subscription.id
    plugin = subscription.plugin
    pluginName = subscription.pluginName
    symbolName = subscription.symbolName
    event = subscription.event
    title = subscription.label ?? subscription.eventTitle ?? subscription.event
    firesAt = subscription.firesAt.flatMap { try? ServerDateCoding.date(from: $0) }
    note = subscription.note
    explained = subscription.explained
  }
}
