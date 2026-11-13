import Observation

@MainActor
@Observable
public final class LocalNetworkPermissionMonitor {
  private static let serverCheckInterval: Duration = .seconds(5)

  private var app: LocalNetworkPermission?
  private var server: LocalNetworkPermission?

  public init() {}

  public var status: LocalNetworkStatus {
    guard let app else { return .checking }

    let appBlocked = app == .denied
    let serverBlocked = server == .denied
    if appBlocked || serverBlocked { return .blocked(app: appBlocked, server: serverBlocked) }
    if app == .unavailable { return .unavailable }
    return .allowed
  }

  public func watch(localServer: (any CodevisorServerClienting)?) async {
    await withDiscardingTaskGroup { group in
      group.addTask { await self.watchApp() }
      guard let localServer else { return }
      group.addTask { await self.watchServer(localServer) }
    }
  }

  private func watchApp() async {
    for await permission in LocalNetworkPermissionProbe.permissions() {
      app = permission
    }
  }

  private func watchServer(_ client: any CodevisorServerClienting) async {
    while !Task.isCancelled {
      server = try? await client.cloudLocalNetworkPermission()
      try? await Task.sleep(for: Self.serverCheckInterval)
    }
  }
}
