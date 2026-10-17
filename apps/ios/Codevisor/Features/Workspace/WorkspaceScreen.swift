import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

struct WorkspaceScreen: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.dismiss) var dismiss
  @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
  @Environment(\.homeLayoutMode) var homeLayoutMode
  @Environment(\.homeSidebarIsTiled) var homeSidebarIsTiled
  @Environment(\.workspaceBarsAreVertical) var barsAreVertical
  let sessionId: UUID?
  var serverId: String? = nil
  var workspaceId: UUID? = nil
  var preferredChatSessionId: UUID? = nil
  var preferredPaneId: UUID? = nil
  var preferredLeafId: UUID? = nil
  var onSelectedPaneChanged: ((WorkspacePaneSelection) -> Void)? = nil
  var initialController: SessionController? = nil
  var isNewChatPresentation = false
  var isPromotingNewChat = false
  var promotionNavigationTitle: WorkspaceNavigationTitle? = nil
  var initialComposerFocusRequest: UUID? = nil
  var onInitialComposerFocusRequestFulfilled: ((UUID) -> Void)? = nil
  var onDraftWillStart: (() -> Void)? = nil
  var onDraftStarted: ((UUID) -> Void)? = nil
  var onDismissNewChat: (() -> Void)? = nil
  var onWorkspaceReady: ((UUID) -> Void)? = nil
  var transcriptPresentationRole: TranscriptPresentationRole = .foreground
  var onSendAnimationCompleted: ((UserSendAnimationRequest) -> Void)? = nil
  var onSendAnimationStarted: ((UserSendAnimationRequest) -> Void)? = nil
  var onComposerWillSend: ((String, CGRect) -> Void)? = nil
  var composerTextEditorHandoffRole: ComposerTextEditorHandoffRole = .none
  var composerTextEditorHandoffID: UUID? = nil

  @State var controllers: [UUID: SessionController] = [:]
  @State var presentedSubagent: SubagentRoute?
  @State var missing = false
  @State var serverConfig: CodevisorServerConfig?
  @State var project: Project?
  @State var paneState: PaneGroupState?
  @State var startedSessionId: UUID?
  @State var draftController: SessionController?
  @State var paneViewIdentities: [UUID: UUID] = [:]
  @State var hasStarted = false
  @State var draftPlaceholderId = UUID()
  @State var convertedChatFocusRequest: (chatSessionId: UUID, request: UUID)?

  var activeSessionId: UUID? { sessionId ?? startedSessionId }

  var isDraft: Bool { activeSessionId == nil && workspaceId == nil }

  var presentsAsStarted: Bool {
    isPromotingNewChat || hasStarted || (isDraft && draftController?.pendingUserMessage != nil)
  }

  var resolvedServerId: String {
    serverId ?? draftController?.project.serverId ?? environment.defaultComposerServerId
  }

  var workspaceEntry: WorkspaceEntry? {
    let entries = environment.navigationStore.workspaceEntries
    if let workspaceId {
      let entry = entries.entry(workspaceId)
      if entry.workspace?.serverId == resolvedServerId { return entry }
    }
    guard let activeSessionId, let indexed = environment.workspaces.workspaceId(forSession: activeSessionId)
    else { return nil }
    let entry = entries.entry(indexed)
    guard let workspace = entry.workspace, workspace.serverId == resolvedServerId,
      workspace.chatSessionIds.contains(activeSessionId)
    else { return nil }
    return entry
  }

  var resolvedWorkspace: Workspace? {
    workspaceEntry?.workspace
  }

  var panes: PaneGroupState {
    if let paneState { return paneState }
    if let workspace = resolvedWorkspace {
      return PaneLayoutProjection.flatten(workspace)
    }
    if let paneStorageId {
      return WorkspacePaneStore.shared.state(
        for: paneStorageId,
        legacySessionIds: legacyPaneSessionIds
      )
    }
    return PaneGroupState.centerInitial(sessionId: draftPlaceholderId)
  }

  var activePane: PaneDescriptorState? {
    panes.selectedPane ?? panes.panes.first
  }

  func session(for id: UUID) -> ChatSession? {
    environment.projectList.session(id, serverId: resolvedServerId)
  }

  var rootSession: ChatSession? { activeSessionId.flatMap(session(for:)) }

  var draftProjectCandidate: Project? {
    guard let remembered = environment.composerDefaults.lastProjectId(forServer: resolvedServerId)
    else { return nil }
    return environment.projectList.fleetActiveProjects.first {
      $0.serverId == resolvedServerId && $0.id == remembered && !$0.isScratch
    }
  }

  var resolvedProject: Project? {
    project
      ?? resolvedWorkspace.flatMap { workspace in
        environment.projectList.projects.first {
          $0.serverId == workspace.serverId && $0.id == workspace.projectId
        }
      }
      ?? draftController?.project
      ?? rootSession.flatMap { session in
        environment.projectList.projects.first {
          $0.serverId == session.serverId && $0.id == session.projectId
        }
      }
  }

  private func cachedController(for chatId: UUID) -> SessionController? {
    guard let session = session(for: chatId) else { return nil }
    return ChatControllerCache.shared.existingController(
      sessionId: chatId,
      serverId: session.serverId
    )
  }

  func chatController(for pane: PaneDescriptorState) -> SessionController? {
    guard let chatId = pane.chatSessionId ?? activeSessionId else { return draftController }
    if chatId == draftPlaceholderId { return draftController }
    return chatController(forChat: chatId)
  }

  func chatController(forChat chatId: UUID) -> SessionController? {
    if let controller = controllers[chatId] { return controller }
    if chatId == sessionId, let initialController { return initialController }
    return cachedController(for: chatId)
  }

  func title(for pane: PaneDescriptorState) -> String {
    switch pane.kind {
    case .chat:
      let title =
        (pane.chatSessionId ?? activeSessionId)
        .flatMap(session(for:))?.title ?? pane.name
      return title.isEmpty ? "New Chat" : title
    case .newTab:
      return "New Tab"
    case .browser:
      return BrowserPaneCache.shared.localTitle(paneId: pane.id) ?? pane.name
    case .terminal, .plugin, .document, .screenSharing, .subagent, .review, .simulator:
      return pane.displayName
    }
  }

  var workspaceCwd: String {
    resolvedWorkspace?.rootDirectory
      ?? rootSession?.cwd
      ?? resolvedProject?.folderURL.path
      ?? ""
  }

  var body: some View {
    ZStack {
      ChatSurfaceBackground()
        .ignoresSafeArea()
      workspaceContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationDestination(item: $presentedSubagent) { SubagentScreen(route: $0) }
    .onChange(of: paneState?.selectedPaneId) { presentedSubagent = nil }
  }

  private var workspaceContent: some View {
    Group {
      if blocksServerContent {
        let machines = environment.machines
        let machine =
          machines.machine(for: resolvedServerId)
          ?? machines.allMachines.first
          ?? CodevisorMachine.local
        ServerAvailabilityView(
          machineId: machine.id,
          availability: screenAvailability,
          machineName: machine.name,
          isLocal: false
        )
      } else if missing {
        ContentUnavailableView("Chat Not Found", systemImage: "questionmark.bubble")
      } else if isDraft, draftController == nil {
        Color.clear
      } else if resolvedProject == nil {
        DelayedWorkspaceLoadingView()
      } else if preferredChatSessionId != nil || preferredPaneId != nil, paneState == nil {
        DelayedWorkspaceLoadingView()
      } else if homeLayoutMode == .split, let pane = activePane {
        EdgeToEdgePaneHost { _, insets in
          paneContent(pane)
            .id(paneViewIdentities[pane.id] ?? pane.id)
            .safeAreaPadding(insets)
        }
      } else if let pane = activePane {
        paneContent(pane)
          .id(paneViewIdentities[pane.id] ?? pane.id)
      } else {
        DelayedWorkspaceLoadingView()
      }
    }
    .navigationTitle(hidesTitleBesideSidebar ? "" : baseTitle)
    .navigationSubtitle(hidesTitleBesideSidebar ? "" : subtitle)
    .navigationBarBackButtonHidden(isNewChatPresentation)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(
      promotionNavigationTitle != nil || (!isDraft && [.chat, .terminal].contains(activePane?.kind))
        ? .editor : .automatic
    )
    .toolbar {
      if !blocksServerContent, let model = activeFileModel {
        FilePaneToolbar(model: model, onNewTab: { addTab() })
      } else {
        if !blocksServerContent, let model = activeReviewModel {
          ReviewPaneToolbar(model: model, title: activePane.map(title(for:)) ?? "Review Changes")
        }
        if !blocksServerContent { simulatorToolbar }
        if !blocksServerContent { screenSharingToolbar }
        WorkspaceScreenToolbar(
          isNewChatPresentation: isNewChatPresentation,
          isPromotingNewChat: isPromotingNewChat,
          blocksServerContent: blocksServerContent,
          isDraft: isDraft,
          onDismissNewChat: { dismissNewChatPresentation() },
          onAddTab: { addTab() },
          showsBackMorph: !barsAreVertical
        )
      }
    }
    .focusedSceneValue(\.workspaceCommandActions, commandActions)
    .task(id: preparationIdentity) {
      IOSNavigationDiagnostics.record(
        "workspace.prepareTask",
        "availability=\(screenAvailability) draft=\(isDraft)"
      )
      guard isDraft || screenAvailability == .ready else { return }
      await prepare()
    }
    .onChange(of: activePane?.id) { old, new in
      IOSNavigationDiagnostics.record(
        "workspace.activePaneChanged",
        "old=\(old.map(Self.diagnosticID) ?? "nil") new=\(new.map(Self.diagnosticID) ?? "nil")"
      )
    }
    .onChange(of: isDraft ? environment.projectList.projects.map(\.id) : []) { _, _ in
      setUpDraftIfNeeded()
    }
    .onChange(of: isDraft ? environment.machines.allMachines.map(\.id) : []) { _, _ in
      setUpDraftIfNeeded()
      guard isDraft, let controller = draftController,
        let canonical = environment.machines.canonicalComposerMachineId(for: controller.project.serverId),
        canonical != controller.project.serverId
      else { return }
      let target =
        environment.projectList.projects.first {
          $0.serverId == canonical && $0.id == controller.project.id
        } ?? .runTargetPlaceholder(serverId: canonical)
      Task {
        await controller.retarget(to: target, serverClient: environment.machines.client(for: canonical))
      }
    }
    .onChange(of: environment.harnessCatalogRevision(for: resolvedServerId)) { _, _ in
      guard let draftController, isDraft else { return }
      draftController.invalidateHarnessCapabilities()
      Task { await draftController.refreshHarnessCapabilities() }
    }
    .onChange(of: workspaceVersion) { _, _ in
      synchronizePaneStateFromWorkspace()
    }
    .onChange(of: preferredRoute) { _, _ in
      applyPreferredRoute()
    }
    .onChange(of: reportedPaneSelection) { _, selection in
      guard let selection else { return }
      onSelectedPaneChanged?(selection)
    }
    .iosNavigationDiagnostics(navigationDiagnosticState)
  }

  private struct PreparationIdentity: Equatable {
    let serverId: String
    let availability: ServerAvailability
  }

  private var preparationIdentity: PreparationIdentity {
    PreparationIdentity(
      serverId: resolvedServerId,
      availability: screenAvailability
    )
  }

  private var screenAvailability: ServerAvailability {
    environment.machines.availability(for: resolvedServerId)
  }

  var blocksServerContent: Bool {
    if isDraft { return false }
    if let pane = activePane, pane.kind == .chat,
      let controller = chatController(for: pane), controller.model != nil
    {
      return false
    }
    if case .ready = screenAvailability {
      return false
    }
    return true
  }

  private var baseTitle: String {
    if let promotionNavigationTitle { return promotionNavigationTitle.title }
    if isDraft { return "New Chat" }
    guard let pane = activePane else { return "" }
    if pane.kind != .chat, let custom = singlePaneTab(showing: pane.id)?.customTitle {
      return custom
    }
    if let simulatorTitle { return simulatorTitle }
    if let screenSharingTitle { return screenSharingTitle }
    return title(for: pane)
  }

  private func singlePaneTab(showing paneId: UUID) -> WorkspaceTab? {
    resolvedWorkspace?.centerTabs.first { tab in
      let groups = tab.root.allGroups
      return groups.count == 1 && groups[0].state.panes.map(\.id) == [paneId]
    }
  }

  private var subtitle: String {
    if let promotionNavigationTitle { return promotionNavigationTitle.subtitle }
    guard !isDraft, activePane?.kind == .chat else { return "" }
    let projectName = resolvedProject.flatMap {
      $0.isScratch || $0.isRunTargetPlaceholder ? nil : $0.name
    }
    return [
      resolvedWorkspace?.name ?? projectName,
      environment.machines.fleetMachineName(for: resolvedServerId),
    ]
    .compactMap { $0 }
    .filter { !$0.isEmpty }
    .joined(separator: " · ")
  }
}
