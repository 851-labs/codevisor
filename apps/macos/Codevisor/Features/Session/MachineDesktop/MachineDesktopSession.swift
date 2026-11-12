import CodevisorClient
import CodevisorCore
import CodevisorCoreMac
import Foundation

@MainActor
final class MachineDesktopSession {
  static let paneType = "machine-desktop"

  let preview: ScreenSharingPane
  let window: ScreenSharingPane
  private let records: [ServerWorkspacePane]
  private let client: any CodevisorServerClienting
  private var registration: Task<Void, any Error>?

  init(
    preview: ScreenSharingPane, window: ScreenSharingPane, workspaceId: UUID, client: any CodevisorServerClienting
  ) {
    self.preview = preview
    self.window = window
    self.client = client
    records = [preview.id, window.id].map { id in
      ServerWorkspacePane(
        id: id.uuidString.lowercased(), workspaceId: workspaceId.uuidString.lowercased(),
        providerId: "codevisor", paneType: Self.paneType, title: "Desktop",
        createdAt: ServerDateCoding.string(from: Date()))
    }
  }

  func register() async throws {
    if let registration { return try await registration.value }
    let task = Task { [client, records] in
      for record in records { _ = try await client.upsertWorkspacePane(record) }
    }
    registration = task
    do {
      try await task.value
    } catch {
      registration = nil
      throw error
    }
  }

  static func paneId(forWorkspace workspaceId: UUID, role: ScreenSharingViewerRole) -> UUID {
    var bytes = workspaceId.uuid
    bytes.8 ^= 0x5A
    bytes.15 ^= role == .watcher ? 0xA5 : 0x3C
    return UUID(uuid: bytes)
  }
}
