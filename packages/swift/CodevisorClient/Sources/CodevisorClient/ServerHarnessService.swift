import ACPKit
import CodevisorProtocol
import Foundation

public protocol HarnessServicing: Sendable {
  func readyHarnesses() async -> [ServerHarness]
  func allHarnesses() async throws -> [ServerHarness]
  func rescanHarnesses() async throws -> [ServerHarness]
  func listSessions(forHarnessId harnessId: String) async throws -> [SessionInfo]
}

public extension HarnessServicing {
  func rescanHarnesses() async throws -> [ServerHarness] {
    try await allHarnesses()
  }
}

public struct ServerHarnessService: HarnessServicing {
  private let client: any CodevisorServerClienting

  public init(client: any CodevisorServerClienting) {
    self.client = client
  }

  public func readyHarnesses() async -> [ServerHarness] {
    do {
      return try await client.listHarnesses().filter { $0.enabled && $0.isReady }
    } catch {
      Log.server.error(
        "Failed to list harnesses; treating as none ready: \(String(describing: error), privacy: .public)"
      )
      return []
    }
  }

  public func allHarnesses() async throws -> [ServerHarness] {
    try await client.listHarnessesWithLifecycle()
  }

  public func rescanHarnesses() async throws -> [ServerHarness] {
    try await client.rescanHarnesses()
  }

  public func listSessions(forHarnessId harnessId: String) async throws -> [SessionInfo] {
    do {
      return try await client.listAgentSessions(harnessId: harnessId)
    } catch CodevisorServerClientError.httpStatus(404, _) {
      return try await codevisorSessions(forHarnessId: harnessId)
    }
  }

  private func codevisorSessions(forHarnessId harnessId: String) async throws -> [SessionInfo] {
    let projects = try await client.listProjects()
    let projectLocations = Dictionary(
      uniqueKeysWithValues: projects.map { ($0.id, $0.locations) }
    )
    return try await client.listSessions()
      .filter { $0.harnessId == harnessId }
      .compactMap { session in
        let locationPath = projectLocations[session.projectId]?
          .first { $0.serverId == session.serverId }?.folderPath
        guard let cwd = session.cwd ?? locationPath else { return nil }
        return SessionInfo(
          sessionId: session.agentSessionId ?? session.id,
          cwd: cwd,
          title: session.title,
          updatedAt: session.updatedAt ?? session.createdAt
        )
      }
  }
}

public extension ServerHarness {
  var isReady: Bool { readiness.resolvedState == .ready }
}

extension ServerHarness: Identifiable {}
