import Foundation

@MainActor
final class CloudHubLink {
  private let factory: CloudAccountController.HubConnectionFactory
  private(set) var hub: CloudHubConnection?

  init(factory: @escaping CloudAccountController.HubConnectionFactory) {
    self.factory = factory
  }

  func connection(for account: CloudAccountController) -> CloudHubConnection {
    if let hub { return hub }
    let hub = factory(account.serverURL, account.credentialStore)
    self.hub = hub
    Self.connect(hub, for: account)
    return hub
  }

  func reconnect() async {
    guard let hub else { return }
    await hub.reconnect()
  }

  func reconcileAuthoritativeMachines(_ machines: [CloudMachine]) async {
    guard let hub else { return }
    await hub.reconcileAuthoritativeMachines(machines)
  }

  func shutDown() async {
    guard let hub else { return }
    self.hub = nil
    await hub.shutdown()
  }

  func shutDownInBackground() {
    guard let hub else { return }
    self.hub = nil
    Task { await hub.shutdown() }
  }

  private static func connect(_ hub: CloudHubConnection, for account: CloudAccountController) {
    Task { [weak account] in
      guard let account else { return }
      await hub.setMachinesChangedHandler(presenceHandler(for: account))
      await hub.setTunnelConfigHandler(tunnelConfigHandler(for: account))
      await hub.connect()
    }
  }

  private static func presenceHandler(
    for account: CloudAccountController
  ) -> @Sendable ([CloudMachine]) -> Void {
    { [weak account] transportMachines in
      guard let account else { return }
      Task { @MainActor in
        account.reconcilePresence(with: transportMachines)
      }
    }
  }

  private static func tunnelConfigHandler(
    for account: CloudAccountController
  ) -> @Sendable (CloudTunnelConfig) -> Void {
    { [weak account] config in
      Task { @MainActor in
        account?.tunnelConfigured(config)
      }
    }
  }
}
