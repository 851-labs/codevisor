import CodevisorClient
import Foundation

struct ScreenSharingStreamOwner: Hashable, Sendable {
  let key: String
  let target: String

  init?(starting request: ServerScreenSharingRequest, target: String) {
    guard let app = request.app else { return nil }

    key = app.key.lowercased()
    self.target = target
  }
}
