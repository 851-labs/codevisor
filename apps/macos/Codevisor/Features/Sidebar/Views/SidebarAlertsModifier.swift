import CodevisorCore
import SwiftUI

/// The sidebar's confirmation and rename alerts, in the same order they were
/// chained on the sidebar content: import, chat rename, workspace rename,
/// archived-item restore.
struct SidebarAlertsModifier: ViewModifier {
    @Binding var pendingImport: PendingSessionImport?
    @Binding var renamingSession: ChatSession?
    @Binding var renameTitle: String
    @Binding var renamingWorkspace: Workspace?
    @Binding var workspaceRenameTitle: String
    @Binding var restoreRequest: ArchivedRestoreRequest?
    let onImport: (PendingSessionImport) -> Void
    let onRenameSession: (ChatSession, String) -> Void
    /// Receives the workspace with its new name already applied and pinned.
    let onRenameWorkspace: (Workspace) -> Void
    let onPerformRestore: (ArchivedRestoreRequest) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Import Existing Chats?",
                isPresented: Binding(
                    get: { pendingImport != nil },
                    set: { if !$0 { pendingImport = nil } }
                ),
                presenting: pendingImport
            ) { pending in
                Button("Import") {
                    onImport(pending)
                }
                Button("Not Now", role: .cancel) {}
            } message: { pending in
                Text(importPromptMessage(for: pending))
            }
            .alert(
                "Rename Chat",
                isPresented: Binding(
                    get: { renamingSession != nil },
                    set: { if !$0 { renamingSession = nil } }
                ),
                presenting: renamingSession
            ) { session in
                TextField("Title", text: $renameTitle)
                Button("Rename") {
                    let trimmed = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onRenameSession(session, trimmed)
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Rename Workspace",
                isPresented: Binding(
                    get: { renamingWorkspace != nil },
                    set: { if !$0 { renamingWorkspace = nil } }
                ),
                presenting: renamingWorkspace
            ) { workspace in
                TextField("Name", text: $workspaceRenameTitle)
                Button("Rename") {
                    let trimmed = workspaceRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    // An explicit rename pins the name so worktree creation does
                    // not replace it.
                    var renamed = workspace
                    renamed.name = trimmed
                    renamed.hasCustomName = true
                    onRenameWorkspace(renamed)
                }
                Button("Cancel", role: .cancel) {}
            }
            // Archived rows are visually identical to live ones, so a click is
            // just as likely to be exploratory as intentional. Confirm before
            // pulling the item back into the sidebar.
            .alert(
                restoreAlertTitle,
                isPresented: Binding(
                    get: { restoreRequest != nil },
                    set: { if !$0 { restoreRequest = nil } }
                ),
                presenting: restoreRequest
            ) { request in
                Button("Restore") { onPerformRestore(request) }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text("“\(request.name)” will move back into the sidebar.")
            }
    }

    private var restoreAlertTitle: String {
        guard let restoreRequest else { return "Restore?" }
        return "Restore \(restoreRequest.kind)?"
    }

    private func importPromptMessage(for pending: PendingSessionImport) -> String {
        let count = pending.sessions.count
        let chats = count == 1 ? "1 existing agent chat" : "\(count) existing agent chats"
        return
            "Codevisor found \(chats) in “\(pending.project.name)”. Import them to continue those conversations here."
    }
}
