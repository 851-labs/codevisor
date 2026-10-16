import CodevisorCore
import CodevisorUI
import ScreenSharingPane
import SimulatorPane
import SwiftUI

struct WorkspacePaneContentView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.windowID) private var windowID
  let pane: PaneDescriptorState
  var surfacePaneID: UUID?
  var layoutNamespaceToken: UUID?
  let filePaneModel: (PaneDescriptorState) -> FilePaneModel
  let reviewPaneModel: (PaneDescriptorState) -> ReviewPaneModel
  var onOpenFiles: (() -> Void)? = nil
  let chatController: (PaneDescriptorState) -> SessionController?
  let activeSessionId: UUID?
  let session: (UUID) -> ChatSession?
  let projectList: ProjectListModel
  let showsRunPickers: Bool
  let initialComposerFocusRequest: UUID?
  let onInitialComposerFocusRequestFulfilled: ((UUID) -> Void)?
  let transcriptPresentationRole: TranscriptPresentationRole
  let onSendAnimationCompleted: ((UserSendAnimationRequest) -> Void)?
  let onSendAnimationStarted: ((UserSendAnimationRequest) -> Void)?
  let onComposerWillSend: ((String, CGRect) -> Void)?
  let preservesComposerFocusOnSend: Bool
  let composerTextEditorHandoffRole: ComposerTextEditorHandoffRole
  let composerTextEditorHandoffID: UUID?
  let isNewChatPresentation: Bool
  let hasStarted: Bool
  let onWorkspaceReady: ((UUID) -> Void)?
  let connectChat: (UUID) async -> Void
  let onConvertToChat: () -> Void
  let onConvertToTerminal: () -> Void
  let onConvertToBrowser: () -> Void
  let onConvertToReview: () -> Void
  let onConvertToSimulator: () -> Void
  let onConvertToScreenSharing: () -> Void
  let onConvertToPlugin: (PluginNewTabOption) -> Void
  let serverConfig: CodevisorServerConfig?
  let workspaceCwd: String
  let machineClient: any CodevisorServerClienting
  let machineId: String
  let browserPaneModel: (PaneDescriptorState) -> BrowserPaneModel
  let pluginPaneModel: (PaneDescriptorState) -> PluginPaneModel
  let simulatorPaneModel: (PaneDescriptorState) -> SimulatorPaneModel?
  let screenSharingPaneModel: (PaneDescriptorState) -> ScreenSharingPaneModel?
  let onRenamePane: (PaneDescriptorState, String) -> Void

  var body: some View {
    switch pane.kind {
    case .chat:
      if let controller = chatController(pane) {
        SessionTranscriptView(
          controller: controller,
          presentationSurface: TranscriptPresentationSurfaceCache.shared.surface(
            for: .init(paneID: surfacePaneID ?? pane.id, isNewChat: isNewChatPresentation, windowID: windowID),
            controller: controller
          ),
          showsRunPickers: showsRunPickers,
          initialComposerFocusRequest: initialComposerFocusRequest,
          onInitialComposerFocusRequestFulfilled:
            onInitialComposerFocusRequestFulfilled,
          presentationRole: transcriptPresentationRole,
          onSendAnimationCompleted: onSendAnimationCompleted,
          onSendAnimationStarted: onSendAnimationStarted,
          onComposerWillSend: onComposerWillSend,
          preservesComposerFocusOnSend: preservesComposerFocusOnSend,
          layoutNamespaceToken: layoutNamespaceToken,
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
        }
      } else if let chatId = pane.chatSessionId ?? activeSessionId {
        DelayedWorkspaceLoadingView()
          .task { await connectChat(chatId) }
      } else {
        DelayedWorkspaceLoadingView()
      }
    case .newTab:
      NewTabPaneView(
        onNewChat: onConvertToChat,
        onNewTerminal: onConvertToTerminal,
        onNewBrowser: onConvertToBrowser,
        onOpenFiles: { onOpenFiles?() },
        onReviewChanges: onConvertToReview,
        onNewSimulator: onConvertToSimulator,
        supportsSimulator: environment.machines.statusByMachineId[machineId]?.supportsSimulator == true,
        onNewScreenSharing: onConvertToScreenSharing,
        supportsScreenSharing: environment.machines.statusByMachineId[machineId]?.supportsScreenSharing == true,
        client: machineClient,
        iconCacheNamespace: machineId,
        onOpenPlugin: onConvertToPlugin
      )
    case .browser:
      BrowserPaneView(model: browserPaneModel(pane))
        .task(id: environment.machines.httpConnectionState(forMachineId: machineId)) {
          await browserPaneModel(pane).connectionDidChange()
        }
    case .simulator:
      if let model = simulatorPaneModel(pane) {
        SimulatorPaneView(model: model)
      } else {
        ContentUnavailableView("Simulator unavailable", systemImage: "iphone")
      }
    case .screenSharing:
      if let model = screenSharingPaneModel(pane) {
        ScreenSharingPaneView(model: model)
      } else {
        ContentUnavailableView("Desktop unavailable", systemImage: "display")
      }
    case .document:
      if pane.documentPath != nil {
        FilePaneView(model: filePaneModel(pane))
      } else {
        ContentUnavailableView("Document unavailable", systemImage: "doc")
      }
    case .review:
      ReviewPaneView(model: reviewPaneModel(pane))
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
    case .subagent:
      EmptyView()
    }
  }

}
