import Foundation
import ACPKit

public struct ImportedSession: Sendable, Equatable {
  public let harnessId: String
  public let info: SessionInfo

  public init(harnessId: String, info: SessionInfo) {
    self.harnessId = harnessId
    self.info = info
  }

  @MainActor
  func chatSession(projectId: UUID, serverId: String, timestamp: Date?) -> ChatSession {
    ChatSession(
      projectId: projectId,
      serverId: serverId,
      harnessId: harnessId,
      agentSessionId: info.sessionId,
      title: info.title ?? "Session",
      origin: .imported,
      createdAt: timestamp ?? Date(),
      updatedAt: timestamp
    )
  }
}

public struct SessionImporter: Sendable {
  private let harnessService: any HarnessServicing

  public init(harnessService: any HarnessServicing) {
    self.harnessService = harnessService
  }

  public func fetchAll() async -> [ImportedSession] {
    let harnesses = await harnessService.readyHarnesses()
    var result: [ImportedSession] = []
    for harness in harnesses {
      do {
        let infos = try await harnessService.listSessions(forHarnessId: harness.id)
        result.append(contentsOf: infos.map { ImportedSession(harnessId: harness.id, info: $0) })
      } catch {
        Log.server.error(
          "Skipping harness \(harness.id, privacy: .public) during session import: \(String(describing: error), privacy: .public)"
        )
      }
    }
    return result
  }
}
