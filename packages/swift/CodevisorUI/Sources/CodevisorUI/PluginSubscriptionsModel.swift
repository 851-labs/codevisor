import CodevisorCore
import Foundation
import Observation

@MainActor
@Observable
public final class PluginSubscriptionsModel {
  public private(set) var subscriptions: [ServerPluginEventSubscription] = []
  public var errorMessage: String?

  @ObservationIgnored private let serverId: String
  @ObservationIgnored private let client: any CodevisorServerClienting

  public init(serverId: String, client: any CodevisorServerClienting) {
    self.serverId = serverId
    self.client = client
  }

  public func load() async {
    do {
      subscriptions = try await client.listPluginEventSubscriptions().filter { $0.plugin == serverId }
      errorMessage = nil
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }

  public func remove(_ subscription: ServerPluginEventSubscription) async {
    do {
      try await client.removePluginEventSubscription(id: subscription.id)
      subscriptions.removeAll { $0.id == subscription.id }
      errorMessage = nil
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
