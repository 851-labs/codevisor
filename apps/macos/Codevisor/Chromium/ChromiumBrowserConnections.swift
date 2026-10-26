import CodevisorClient
import Foundation

@MainActor
final class ChromiumBrowserConnections {
  static let shared = ChromiumBrowserConnections()
  private var sessions: [String: Task<ServerBrowserProxySession, Error>] = [:]

  func connection(
    machineId: String, client: any CodevisorServerClienting, resolveBaseURL: @MainActor () async -> URL?
  ) async throws -> ChromiumBrowserConnection {
    let session = try await session(machineId: machineId, client: client)
    guard let endpoint = await resolveBaseURL(), let host = endpoint.host, ["http", "https"].contains(endpoint.scheme)
    else { throw URLError(.notConnectedToInternet) }
    let usesTLS = endpoint.scheme == "https"
    return ChromiumBrowserConnection(
      host: host, port: endpoint.port ?? (usesTLS ? 443 : 80), usesTLS: usesTLS,
      username: session.username, password: session.password)
  }

  func renewCredentials(of view: CVChromiumView, machineId: String, client: any CodevisorServerClienting) {
    view.proxyCredentialsRejected = { [weak self] username, password, reply in
      Task { @MainActor [weak self] in
        let rejected = ServerBrowserProxySession(username: username, password: password)
        let session = await self?.renewedSession(machineId: machineId, client: client, rejecting: rejected)
        reply(session?.username, session?.password)
      }
    }
  }

  private func renewedSession(
    machineId: String, client: any CodevisorServerClienting, rejecting rejected: ServerBrowserProxySession
  ) async -> ServerBrowserProxySession? {
    if let current = try? await sessions[machineId]?.value, current == rejected { sessions[machineId] = nil }
    return try? await session(machineId: machineId, client: client)
  }

  private func session(
    machineId: String, client: any CodevisorServerClienting
  ) async throws -> ServerBrowserProxySession {
    let task = sessions[machineId] ?? Task { try await Self.fetchSession(client) }
    sessions[machineId] = task
    do {
      return try await task.value
    } catch {
      if sessions[machineId] == task { sessions[machineId] = nil }
      throw error
    }
  }

  private static func fetchSession(_ client: any CodevisorServerClienting) async throws -> ServerBrowserProxySession {
    async let info = client.info()
    async let session = client.browserProxySession()
    guard let features = try await info.features, features.contains("browser-http-proxy-v1"),
      features.contains("browser-state-v1")
    else { throw ServerUpdateRequired() }
    return try await session
  }

  private struct ServerUpdateRequired: LocalizedError {
    var errorDescription: String? { "Update the Codevisor server on this machine to use Chromium browser panes." }
  }
}
