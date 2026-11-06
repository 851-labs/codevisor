import SwiftUI

struct ChildAgentSplitRequests: ViewModifier {
  let store: SessionStore
  let workspaceId: UUID
  let onOpen: (ChildAgentSplitRequest) -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: store.childAgentSplitRequest, initial: true) { _, request in
        guard let request, store.childAgentSplitRequest == request, request.workspaceId == workspaceId else { return }
        store.childAgentSplitRequest = nil
        onOpen(request)
      }
  }
}
