import CodevisorClient
import Foundation
import Observation

@Observable
final class WorkspaceInspectorCheckoutSize {
  private static let refreshInterval = Duration.seconds(60)

  private var bytes: [UUID: Int64] = [:]

  func formatted(for workspaceId: UUID) -> String? {
    bytes[workspaceId]?.formatted(.byteCount(style: .file))
  }

  func keepLoading(workspaceId: UUID, client: any CodevisorServerClienting) async {
    while !Task.isCancelled {
      await load(workspaceId: workspaceId, client: client)
      try? await Task.sleep(for: Self.refreshInterval)
    }
  }

  private func load(workspaceId: UUID, client: any CodevisorServerClienting) async {
    guard let loaded = try? await client.workspaceSize(workspaceId: workspaceId) else { return }
    bytes[workspaceId] = loaded
  }
}
