import SwiftUI
import CodevisorCore

/// The one-click workspace path (project card click, sidebar "New workspace
/// here"): creates a workspace immediately with the project name — rooted at
/// the project folder, opening on its eager chat's composer — and routes
/// into it. Creation is local and synchronous; nothing to watch, nothing to
/// configure. Worktrees are chosen later, in the composer.
struct QuickWorkspaceCreationView: View {
    let project: Project
    let store: SessionStore
    @Binding var selection: SidebarSelection?

    /// One-shot latch: `task(id:)` re-fires on remounts, and a second run
    /// would mint a second workspace.
    @State private var created = false

    var body: some View {
        Color.clear
            .task(id: project.id) {
                guard !created else { return }
                created = true
                let session = store.createWorkspaceSession(in: project)
                selection = .session(serverId: session.serverId, id: session.id)
            }
    }
}
