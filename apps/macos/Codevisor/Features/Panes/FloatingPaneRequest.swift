import CodevisorCore
import Foundation

struct FloatingPaneRequest {
  let key: FloatingPaneKey
  let owner: UUID
  let activating: Bool
  let attention: FloatingPaneAttention
  let onClose: () -> Void
}

struct FloatingPaneAttention {
  let coordinator: SessionAttentionCoordinator
  let session: () -> SessionAttentionFocus?

  func publish(owner: ObjectIdentifier, isKey: Bool) {
    let session = session()
    coordinator.updateOpenSession(owner: owner, session: session)
    coordinator.updateFocus(owner: owner, session: isKey ? session : nil)
  }

  func clear(owner: ObjectIdentifier) {
    coordinator.updateOpenSession(owner: owner, session: nil)
    coordinator.updateFocus(owner: owner, session: nil)
  }
}
