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
    let task = sessions[machineId] ?? Task { try await client.browserProxySession() }
    sessions[machineId] = task
    do {
      return try await task.value
    } catch {
      if sessions[machineId] == task { sessions[machineId] = nil }
      throw error
    }
  }
}
