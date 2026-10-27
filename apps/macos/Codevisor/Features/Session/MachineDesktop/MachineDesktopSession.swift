import CodevisorClient
import CodevisorCore
import Foundation

@MainActor
final class MachineDesktopSession {
  static let paneType = "machine-desktop"

  let pane: ScreenSharingPane
  private let record: ServerWorkspacePane
  private let client: any CodevisorServerClienting
  private var registration: Task<Bool, Never>?

  init(pane: ScreenSharingPane, workspaceId: UUID, client: any CodevisorServerClienting) {
    self.pane = pane
    self.client = client
    record = ServerWorkspacePane(
      id: pane.id.uuidString.lowercased(), workspaceId: workspaceId.uuidString.lowercased(),
      providerId: "codevisor", paneType: Self.paneType, title: "Desktop",
      createdAt: ServerDateCoding.string(from: Date()))
  }

  func register() async -> Bool {
    if let registration { return await registration.value }
    let task = Task { [client, record] in (try? await client.upsertWorkspacePane(record)) != nil }
    registration = task
    let registered = await task.value
    if !registered { registration = nil }
    return registered
  }

  static func paneId(forWorkspace workspaceId: UUID) -> UUID {
    var bytes = workspaceId.uuid
    bytes.8 ^= 0x5A
    bytes.15 ^= 0xA5
    return UUID(uuid: bytes)
  }
}
