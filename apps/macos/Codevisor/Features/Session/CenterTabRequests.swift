import SwiftUI

struct CenterTabRequests: ViewModifier {
  let store: SessionStore
  let workspaceId: UUID
  let onClose: (UUID) -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: store.closeCenterTabRequest, initial: true) { _, request in
        guard let request, store.closeCenterTabRequest == request, request.workspaceId == workspaceId else { return }
        store.closeCenterTabRequest = nil
        onClose(request.tabId)
      }
  }
}
