import Foundation

@testable import CodevisorCore

final class FakeSetupRequests: @unchecked Sendable {
  private let lock = NSLock()
  private var _worktreeProjectIds: [UUID] = []
  private var _scratchProjectIds: [UUID] = []

  var worktreeProjectIds: [UUID] { lock.withLock { _worktreeProjectIds } }
  var scratchProjectIds: [UUID] { lock.withLock { _scratchProjectIds } }

  func recordWorktree(for projectId: UUID) {
    lock.withLock { _worktreeProjectIds.append(projectId) }
  }

  func recordScratchProject(_ id: UUID) {
    lock.withLock { _scratchProjectIds.append(id) }
  }
}

extension FakeSessionServerClient {
  func createWorktree(projectId: UUID, id: String?, name: String?) async throws -> ServerWorktree {
    setupRequests.recordWorktree(for: projectId)
    return try JSONDecoder().decode(
      ServerWorktree.self,
      from: Data(
        """
        {"id":"\(id ?? "worktree")","projectId":"\(projectId.uuidString)","serverId":"local",
        "name":"mugwort","branch":"codevisor/mugwort","path":"/fixture/worktrees/mugwort",
        "createdAt":"2026-10-22T12:00:00Z"}
        """.utf8))
  }

  func createScratchProject(id: UUID) async throws -> ServerProject {
    setupRequests.recordScratchProject(id)
    var scratch = serverProject(from: .fromFolder(URL(fileURLWithPath: "/fixture/workspaces/burrito"), id: id))
    scratch.isScratch = true
    return scratch
  }
}
