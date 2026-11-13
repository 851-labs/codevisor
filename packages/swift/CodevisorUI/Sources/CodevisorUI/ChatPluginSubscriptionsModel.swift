import CodevisorCore
import Foundation
import Observation

@MainActor
@Observable
public final class ChatPluginSubscriptionsModel {
  public private(set) var events: [SubscribedPluginEvent] = []

  @ObservationIgnored private var sessionId: UUID?

  public init() {}

  public func load(sessionId: UUID?, client: any CodevisorServerClienting) async {
    if sessionId != self.sessionId { show([], for: sessionId) }
    guard let sessionId else { return }
    guard let subscriptions = try? await client.listPluginEventSubscriptions(sessionId: sessionId) else { return }
    guard !Task.isCancelled else { return }

    show(subscriptions.map(SubscribedPluginEvent.init), for: sessionId)
  }

  public func remove(_ event: SubscribedPluginEvent, client: any CodevisorServerClienting) async -> Bool {
    do {
      try await client.removePluginEventSubscription(id: event.id)
    } catch {
      return false
    }
    events.removeAll { $0.id == event.id }
    return true
  }

  private func show(_ events: [SubscribedPluginEvent], for sessionId: UUID?) {
    self.sessionId = sessionId
    guard events != self.events else { return }
    self.events = events
  }
}
