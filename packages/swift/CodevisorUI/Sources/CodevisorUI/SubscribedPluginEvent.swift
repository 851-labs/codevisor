import CodevisorCore

public struct SubscribedPluginEvent: Equatable, Identifiable, Sendable {
  public let plugin: String
  public let pluginName: String
  public let event: String
  public let eventTitle: String

  public var id: String { "\(plugin)/\(event)" }

  public var label: String { "\(pluginName) · \(eventTitle)" }

  init(_ subscription: ServerPluginEventSubscription) {
    plugin = subscription.plugin
    pluginName = subscription.pluginName
    event = subscription.event
    eventTitle = subscription.eventTitle ?? subscription.event
  }

  public static func distinct(_ subscriptions: [ServerPluginEventSubscription]) -> [SubscribedPluginEvent] {
    var seen: Set<String> = []
    return subscriptions.map(SubscribedPluginEvent.init).filter { seen.insert($0.id).inserted }
  }
}
