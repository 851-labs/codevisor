import CodevisorClient
import Foundation
import Observation

@Observable
final class WorkspaceInspectorCheckoutSize {
  private static let refreshInterval = Duration.seconds(60)

  private(set) var bytes: Int64?

  var formatted: String? {
    bytes?.formatted(.byteCount(style: .file))
  }

  func keepLoading(workspaceId: UUID, client: any CodevisorServerClienting) async {
    bytes = nil
    while !Task.isCancelled {
      await load(workspaceId: workspaceId, client: client)
      try? await Task.sleep(for: Self.refreshInterval)
    }
  }

  private func load(workspaceId: UUID, client: any CodevisorServerClienting) async {
    guard let loaded = try? await client.workspaceSize(workspaceId: workspaceId) else { return }
    bytes = loaded
  }
}
