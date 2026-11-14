import CodevisorCoreMac
import Foundation

@MainActor
final class MachineDesktopSession {
  let preview: ScreenSharingPane
  let window: ScreenSharingPane

  init(preview: ScreenSharingPane, window: ScreenSharingPane) {
    self.preview = preview
    self.window = window
  }

  static func paneId(forWorkspace workspaceId: UUID, role: ScreenSharingViewerRole) -> UUID {
    var bytes = workspaceId.uuid
    bytes.8 ^= 0x5A
    bytes.15 ^= role == .watcher ? 0xA5 : 0x3C
    return UUID(uuid: bytes)
  }
}
