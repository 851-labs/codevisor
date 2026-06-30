import SwiftUI
import HerdManCore

/// Hosts a session: resolves its cached `SessionController` from the store and
/// shows the session screen.
struct SessionContainerView: View {
    let session: ChatSession
    let workspace: Workspace
    let store: SessionStore

    @State private var controller: SessionController?

    var body: some View {
        Group {
            if let controller {
                SessionScreen(controller: controller)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(session.title)
        .task(id: session.id) {
            let controller = store.controller(for: session, workspace: workspace)
            self.controller = controller
            if !controller.isPrepared && !controller.isConnected {
                await controller.prepare()
            }
            // Eagerly connect so the model/reasoning pickers are available for
            // follow-ups (no-op if already connected, e.g. the new-chat handoff).
            if !AppPreview.isRunning {
                await controller.connectIfNeeded()
            }
        }
    }
}
