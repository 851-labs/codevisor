import CodevisorClient
import Foundation

enum ScreenSharingStreamOwner: Hashable, Sendable {
  case app(key: String, target: String)
  case pane(workspaceId: UUID, paneId: UUID, viewerId: UUID)

  init(starting request: ServerScreenSharingRequest, target: String) {
    guard let app = request.app else {
      self.init(paneOf: request)
      return
    }

    self = .app(key: app.key.lowercased(), target: target)
  }

  init(paneOf request: ServerScreenSharingRequest) {
    self = .pane(workspaceId: request.workspaceId, paneId: request.paneId, viewerId: request.viewerId)
  }

  var isApp: Bool {
    if case .app = self { true } else { false }
  }
}
