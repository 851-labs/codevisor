import CodevisorClient
import Foundation
import Observation

@Observable
final class WorkspaceInspectorMirrors {
  private static let refreshInterval = Duration.seconds(5)

  private(set) var mirrors: [ServerWorkspaceMirror] = []

  func keepLoading(workspaceId: UUID, client: any CodevisorServerClienting) async {
    while !Task.isCancelled {
      await load(workspaceId: workspaceId, client: client)
      try? await Task.sleep(for: Self.refreshInterval)
    }
  }

  func remove(_ mirror: ServerWorkspaceMirror, workspaceId: UUID, client: any CodevisorServerClienting) async {
    mirrors.removeAll { $0.id == mirror.id }
    try? await client.stopWorkspaceMirror(workspaceId: workspaceId, machineId: mirror.machine.machineId)
    await load(workspaceId: workspaceId, client: client)
  }

  private func load(workspaceId: UUID, client: any CodevisorServerClienting) async {
    guard let loaded = try? await client.workspaceMirrors(workspaceId: workspaceId) else { return }
    mirrors = loaded
  }
}
