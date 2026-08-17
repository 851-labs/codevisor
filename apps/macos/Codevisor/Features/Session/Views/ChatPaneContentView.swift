import CodevisorCore
import SwiftUI

/// A chat pane's content: the referenced session's chat, or (for a
/// draft) the in-pane new-chat composer that creates the session and
/// binds it to the pane on first send. Multi-chat workspaces resolve
/// each pane's controller independently.
struct ChatPaneContentView: View {
    let descriptor: PaneDescriptorState
    let group: PaneGroupModel?
    let focus: TerminalFocusController
    let session: ChatSession
    let project: Project
    let store: SessionStore
    let environment: AppEnvironment

    var body: some View {
        if let chatSessionId = descriptor.chatSessionId {
            if let chatSession = environment.projectList.sessions.first(where: {
                $0.serverId == session.serverId && $0.id == chatSessionId
            }),
                let chatProject = environment.projectList.projects.first(where: {
                    $0.serverId == session.serverId && $0.id == chatSession.projectId
                })
            {
                if isUnstarted(chatSession) {
                    // An eagerly created chat that hasn't had its first
                    // message: still the new-chat composer (harness choice
                    // and all) — the session record just already exists for
                    // the sidebar. First send fills it in.
                    NewChatView(
                        store: store,
                        selection: .constant(nil),
                        preferredProjectId: chatProject.id,
                        explicitProjectId: chatProject.id,
                        paneDraftId: descriptor.id,
                        onCreatedInPane: { created in
                            (group ?? store.centerPaneGroup(for: session, project: project))
                                .assignChatSession(
                                    paneId: descriptor.id,
                                    sessionId: created.id,
                                    name: created.title
                                )
                        },
                        preCreatedSession: chatSession,
                        paneFocus: focus,
                        hostWorkspaceId: store.workspace(for: session, project: project).id
                    )
                    .reportsPresentationReadyAfterLayout(
                        PanePresentationReadyEvent(
                            paneId: descriptor.id,
                            chatSessionId: chatSession.id
                        ))
                } else {
                    ChatScreen(
                        controller: store.controller(for: chatSession, project: chatProject),
                        focus: focus
                    )
                }
            } else {
                // The referenced session was deleted (e.g. from another
                // device). Offer a fresh start in place instead of a
                // dead end.
                VStack(spacing: 12) {
                    Text("This chat no longer exists")
                        .foregroundStyle(.secondary)
                    Button("Reset Tab") {
                        group?.resetChatPaneToPlaceholder(id: descriptor.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .reportsPresentationReadyAfterLayout(
                    PanePresentationReadyEvent(
                        paneId: descriptor.id,
                        chatSessionId: descriptor.chatSessionId
                    ))
            }
        } else {
            NewChatView(
                store: store,
                selection: .constant(nil),
                preferredProjectId: project.id,
                explicitProjectId: project.id,
                paneDraftId: descriptor.id,
                onCreatedInPane: { created in
                    // Bind through the pane's OWNING group (the draft may
                    // live in any split leaf, not just the primary).
                    (group ?? store.centerPaneGroup(for: session, project: project))
                        .assignChatSession(
                            paneId: descriptor.id,
                            sessionId: created.id,
                            name: created.title
                        )
                },
                hostWorkspaceId: store.workspace(for: session, project: project).id
            )
            .reportsPresentationReadyAfterLayout(
                PanePresentationReadyEvent(paneId: descriptor.id, chatSessionId: nil)
            )
        }
    }

    /// Whether an established chat should use the centered New Chat treatment.
    /// First-send setup transitions into the transcript immediately; a failed
    /// setup explicitly returns here without deleting the session or workspace.
    private func isUnstarted(_ chatSession: ChatSession) -> Bool {
        guard let live = store.activeController(for: chatSession) else {
            return chatSession.agentSessionId == nil
        }
        // New Chat eagerly connects so its model/reasoning controls are ready.
        // Only an accepted first send — never that preparation connection —
        // moves the pane into the transcript.
        if live.shouldShowNewChatComposer { return true }
        if live.hasAcceptedFirstSend { return false }
        guard chatSession.agentSessionId == nil else { return false }
        return
            !(live.isConnected
            || live.isConnecting
            || live.isSending
            || live.pendingUserMessage != nil)
    }
}
