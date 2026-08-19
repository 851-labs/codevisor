import CodevisorCore
import CodevisorUI
import SwiftUI

/// One full-screen pane body: a chat transcript, the new-tab page, or a
/// terminal. All state stays with WorkspaceScreen; this view receives the
/// resolved values and closures for the pane it renders.
struct WorkspacePaneContentView: View {
    let pane: PaneDescriptorState
    /// Resolved via the cache (and the draft controller) so an already-live
    /// chat renders on the FIRST frame — a just-sent message must never flash
    /// a spinner over itself.
    let chatController: (PaneDescriptorState) -> SessionController?
    let activeSessionId: UUID?
    let session: (UUID) -> ChatSession?
    let projectList: ProjectListModel
    let showsRunPickers: Bool
    let initialComposerFocusRequest: UUID?
    let onInitialComposerFocusRequestFulfilled: ((UUID) -> Void)?
    let transcriptPresentationRole: TranscriptPresentationRole
    let onSendAnimationCompleted: ((UserSendAnimationRequest) -> Void)?
    let onSendAnimationStarted:
        (
            (
                UserSendAnimationRequest,
                TranscriptSendAnimationTarget
            ) -> Bool
        )?
    let onComposerWillSend: ((String, CGRect) -> Void)?
    let preservesComposerFocusOnSend: Bool
    let composerTextEditorHandoffRole: ComposerTextEditorHandoffRole
    let composerTextEditorHandoffID: UUID?
    let isNewChatPresentation: Bool
    let hasStarted: Bool
    let onWorkspaceReady: ((UUID) -> Void)?
    let connectChat: (UUID) async -> Void
    let newTabProjectName: String
    let onConvertToChat: () -> Void
    let onConvertToTerminal: () -> Void
    let onConvertToPlugin: (PluginNewTabOption) -> Void
    let serverConfig: CodevisorServerConfig?
    let workspaceCwd: String
    /// The machine's API client, for the New Tab page's plugin pane rows.
    let machineClient: any CodevisorServerClienting
    /// The pane's cached plugin model (webview + load state), resolved by
    /// WorkspaceScreen so the cache sees every visibility change.
    let pluginPaneModel: (PaneDescriptorState) -> PluginPaneModel
    /// `codevisor.setTitle` from a plugin pane: rename that pane's tab.
    let onRenamePane: (PaneDescriptorState, String) -> Void

    var body: some View {
        switch pane.kind {
        case .chat:
            if let controller = chatController(pane) {
                SessionTranscriptView(
                    controller: controller,
                    // A draft picks where it will run; sending fixes that, so
                    // the chips animate away in place.
                    showsRunPickers: showsRunPickers,
                    initialComposerFocusRequest: initialComposerFocusRequest,
                    onInitialComposerFocusRequestFulfilled:
                        onInitialComposerFocusRequestFulfilled,
                    presentationRole: transcriptPresentationRole,
                    onSendAnimationCompleted: onSendAnimationCompleted,
                    onSendAnimationStarted: onSendAnimationStarted,
                    onComposerWillSend: onComposerWillSend,
                    preservesComposerFocusOnSend: preservesComposerFocusOnSend,
                    composerTextEditorHandoffRole: composerTextEditorHandoffRole,
                    composerTextEditorHandoffID: composerTextEditorHandoffID
                )
                .onAppear {
                    guard let chatId = pane.chatSessionId ?? activeSessionId,
                        session(chatId) != nil
                    else { return }
                    if !isNewChatPresentation {
                        onWorkspaceReady?(chatId)
                    }
                    if transcriptPresentationRole == .foreground {
                        controller.rememberCurrentComposerConfiguration()
                    }
                }
                .onChange(of: transcriptPresentationRole) { _, role in
                    if role == .foreground {
                        controller.rememberCurrentComposerConfiguration()
                    }
                }
            } else if let chatId = pane.chatSessionId ?? activeSessionId {
                DelayedWorkspaceLoadingView()
                    .task { await connectChat(chatId) }
            } else {
                DelayedWorkspaceLoadingView()
            }
        case .newTab:
            NewTabPaneView(
                projectName: newTabProjectName,
                onNewChat: onConvertToChat,
                onNewTerminal: onConvertToTerminal,
                client: machineClient,
                onOpenPlugin: onConvertToPlugin
            )
        case .plugin:
            PluginPaneView(
                model: pluginPaneModel(pane),
                onRename: { onRenamePane(pane, $0) }
            )
        case .terminal:
            if let serverConfig {
                TerminalPaneView(
                    terminalKey: pane.terminalKey,
                    cwd: workspaceCwd,
                    config: serverConfig
                )
            } else {
                ContentUnavailableView("No Machine", systemImage: "bolt.slash")
            }
        }
    }

}
