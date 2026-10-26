import AppKit
import CodevisorClient
import CodevisorUI

@MainActor
final class ChromiumSpareBrowsers {
  static let shared = ChromiumSpareBrowsers()
  private static let warmUpDelay: Duration = .seconds(1)

  private struct Spare {
    let view: CVChromiumView
    let connection: ChromiumBrowserConnection
    let host: ChromiumBackgroundHost
  }

  private var spares: [String: Spare] = [:]
  private var warmUps: [String: Task<Void, Never>] = [:]

  func take(
    machineId: String, connection: ChromiumBrowserConnection? = nil
  ) -> (view: CVChromiumView, connection: ChromiumBrowserConnection)? {
    guard let spare = spares[machineId] else { return nil }
    if let connection, spare.connection != connection {
      discard(machineId: machineId)
      return nil
    }
    guard spare.view.browserIsReady, ChromiumProfiles.shared.cookieSync(machineId: machineId)?.isCurrent == true
    else { return nil }
    spares[machineId] = nil
    spare.view.browserReady = nil
    spare.view.browserClosed = nil
    spare.view.loadFailed = nil
    spare.view.removeFromSuperview()
    spare.host.close()
    return (spare.view, spare.connection)
  }

  func prepare(machineId: String, connection: ChromiumBrowserConnection, client: any CodevisorServerClienting) {
    guard warmUps[machineId] == nil, spares[machineId]?.connection != connection else { return }
    warmUps[machineId] = Task { [weak self] in
      try? await Task.sleep(for: Self.warmUpDelay)
      guard let self, !Task.isCancelled else { return }
      warmUps[machineId] = nil
      guard spares[machineId]?.connection != connection else { return }
      discard(machineId: machineId)
      spares[machineId] = makeSpare(machineId: machineId, connection: connection, client: client)
    }
  }

  func isStale(
    _ connection: ChromiumBrowserConnection, machineId: String, client: any CodevisorServerClienting,
    resolveBaseURL: @MainActor () async -> URL?
  ) async -> Bool {
    guard
      let current = try? await ChromiumBrowserConnections.shared.connection(
        machineId: machineId, client: client, resolveBaseURL: resolveBaseURL)
    else { return false }
    prepare(machineId: machineId, connection: current, client: client)
    return current != connection
  }

  func discard(machineId: String) {
    warmUps.removeValue(forKey: machineId)?.cancel()
    guard let spare = spares.removeValue(forKey: machineId) else { return }
    ChromiumProfiles.shared.detach(spare.view, machineId: machineId)
    spare.view.closeBrowser()
    spare.view.removeFromSuperview()
    spare.host.close()
  }

  private func makeSpare(
    machineId: String, connection: ChromiumBrowserConnection, client: any CodevisorServerClienting
  ) -> Spare {
    let view = connection.makeView(machineId: machineId, address: "about:blank")
    ChromiumBrowserConnections.shared.renewCredentials(of: view, machineId: machineId, client: client)
    view.browserReady = { [weak view] in
      guard let view else { return }
      MainActor.assumeIsolated { _ = ChromiumProfiles.shared.attach(view, machineId: machineId, client: client) }
    }
    view.browserClosed = { [weak self, weak view] _ in
      MainActor.assumeIsolated {
        guard let self, self.spares[machineId]?.view === view else { return }
        self.discard(machineId: machineId)
      }
    }
    view.loadFailed = { [weak self, weak view] _, _, _ in
      MainActor.assumeIsolated {
        guard let self, self.spares[machineId]?.view === view else { return }
        self.discard(machineId: machineId)
      }
    }
    let host = ChromiumBackgroundHost()
    host.host(view)
    return Spare(view: view, connection: connection, host: host)
  }
}
