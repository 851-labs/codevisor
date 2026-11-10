import AppKit
import CodevisorClient

enum WorkspaceFileRemoval {
  static func remove(
    _ entries: [ServerFileEntry], isLocal: Bool, client: any CodevisorServerClienting
  ) async throws {
    guard isLocal else {
      try await client.deleteFiles(paths: entries.map(\.path))
      return
    }

    _ = try await NSWorkspace.shared.recycle(entries.map { URL(fileURLWithPath: $0.path) })
  }
}
