import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CodevisorCore
import CodevisorUI

private struct PaneClickZoneCapture: NSViewRepresentable {
  let onReady: (NSView) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { onReady(view) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct DelayedNewChatLoadingView: View {
  @State private var showsSpinner = false

  var body: some View {
    ZStack {
      Color.clear
      if showsSpinner {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Loading projects")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return
      }
      showsSpinner = true
    }
  }
}

struct NewChatView: View {
  static let favoriteProjectsKey = "composer.favoriteProjects"

  @Environment(AppEnvironment.self) var environment
  let store: SessionStore
  @Binding var selection: SidebarSelection?
  var initialProjectTarget: NewChatTarget?
  var paneDraftId: UUID? = nil
  var onCreatedInPane: ((ChatSession) -> Void)? = nil
  var preCreatedSession: ChatSession? = nil
  var paneFocus: TerminalFocusController? = nil
  var hostWorkspaceId: UUID? = nil
  var requiresInitialProjectResolution = false
  var onInitialProjectResolutionCompleted: (() -> Void)? = nil

  @State var controller: SessionController?
  @State private var sendLanding = NewChatSendLanding()
  @State var selectedProjectId: UUID?
  @State private var appliedInitialProjectTarget: NewChatTarget?
  @State private var focus = TerminalFocusController()
  @State var hoveredRunPicker: RunPicker?
  @State var isRunLocationMenuPresented = false
  @State var pendingSetupGroupID: ProjectGroup.ID?
  @State var projectSetup: ProjectMachineSetup?
  @ClientPreference("composer.favoriteMachines", default: [])
  var favoriteMachineIDs: [String]
  @ClientPreference(Self.favoriteProjectsKey, default: [])
  var favoriteProjectIDs: [ProjectGroup.ID]
  @Namespace private var composerGlassNamespace
  @Environment(\.openSettings) var openSettings

  private var selectedProject: Project? {
    projects.first { $0.id == selectedProjectId && !$0.isScratch }
  }

  var body: some View {
    if paneDraftId == nil {
      machineScopedBody
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    } else {
      machineScopedBody
    }
  }

  var content: some View {
    VStack {
      if requiresInitialProjectResolution {
        DelayedNewChatLoadingView()
      } else {
        Spacer()
        Spacer()
        VStack(spacing: 22) {
          title
          if let controller {
            VStack(alignment: .leading, spacing: 8) {
              GlassEffectContainer(spacing: ComposerGlassStyle.clusterSpacing) {
                VStack(alignment: .leading, spacing: ComposerGlassStyle.clusterSpacing) {
                  if let message = controller.modelUnavailableMessage {
                    ComposerNoticeRail(
                      message,
                      kind: .warning,
                      onDismiss: { controller.dismissModelUnavailableNotice() }
                    )
                  }
                  sandboxUnavailableNotice(controller)
                  ComposerCard(
                    controller: controller,
                    onTextViewReady: { textView in
                      focus.composerTextView = textView
                      if let paneFocus, let chatId = preCreatedSession?.id {
                        paneFocus.registerComposer(textView, forChat: chatId)
                      } else {
                        DispatchQueue.main.async { focus.focusComposer() }
                      }
                    },
                    focus: paneFocus ?? focus,
                    focusChatId: preCreatedSession?.id,
                    glassNamespace: composerGlassNamespace
                  )
                  .reportsFirstLaunchComposerFrame()
                  if showsRunPickers {
                    HStack(spacing: 4) {
                      if showsMachinePicker {
                        machinePicker(controller)
                        runPickerDivider(between: .machine, and: .project)
                      }
                      projectPicker(controller)
                      if showsRunLocationPicker(controller) {
                        runPickerDivider(between: .project, and: .location)
                        runLocationPicker(controller)
                      }
                    }
                    .font(.callout)
                    .disabled(controller.isSubmitting)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .glassEffectID(
                      ComposerGlassElement.newChatConfiguration.rawValue,
                      in: composerGlassNamespace
                    )
                    .glassEffectTransition(.matchedGeometry)
                  }
                }
              }
              statusLabel(controller)
            }
            .frame(maxWidth: 720)
          }
        }
        .frame(maxWidth: 720)
        .padding()
        Spacer()
        Spacer()
        Spacer()
      }
    }
    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    .onGeometryChange(for: CGRect.self) {
      $0.frame(in: .global)
    } action: { frame in
      sendLanding.pageFrame = frame
    }
    .onChange(of: controller?.isSubmitting ?? false) { wasSubmitting, isSubmitting in
      guard wasSubmitting, !isSubmitting, let controller else { return }
      let session = ObjectIdentifier(controller)
      guard sendLanding.holds(session) else { return }
      TranscriptSendStaging.shared.cancel(session: session)
    }
    .overlay(alignment: .top) {
      if let controller, case let .failed(message) = controller.status {
        setupFailureBanner(message)
          .frame(maxWidth: 720)
          .padding(.horizontal, 16)
          .padding(.top, 12)
      }
    }
    .background {
      if let paneFocus, let chatId = preCreatedSession?.id {
        PaneClickZoneCapture { view in
          paneFocus.registerTranscript(view, forChat: chatId)
        }
      }
    }
    .attachmentDropTarget(controller)
    .sheet(isPresented: isShowingProjectSetup) { projectSetupSheet }
    .task(id: environment.machines.sandboxProfilesLoadKey(composerId: composerServerId)) {
      let machines = environment.machines
      await environment.machines.sandboxProfiles.load(
        composerId: composerServerId, from: machines.client(for: composerServerId)
      ) { machines.sandboxHostConnection(forServerId: $0) }
    }
    .onChange(of: controller?.sandboxTargetAvailability) { _, _ in
      controller?.refreshSandboxPrewarm()
    }
    .onChange(of: projects.map(\.id)) { _, _ in
      if controller == nil, !requiresInitialProjectResolution {
        setUpController()
      }
    }
    .onChange(of: selectedDraftProjectIsDeleted, initial: true) { _, isDeleted in
      if isDeleted, let controller { selectNoProject(controller) }
    }
    .task(id: composerPreparationIdentity) {
      await refreshComposerTarget()
    }
    .task(id: setupIdentity) {
      guard !requiresInitialProjectResolution else { return }
      setUpController()
    }
    #if DEBUG
      .task {
        guard AppStoreScreenshotData.opensRunLocationMenu else { return }
        try? await Task.sleep(for: .seconds(1))
        isRunLocationMenuPresented = true
      }
    #endif
    .onChange(of: harnessCatalogRevision) { _, _ in
      guard let controller else { return }
      controller.invalidateHarnessCapabilities()
      Task { await controller.refreshHarnessCapabilities() }
    }
    .onChange(of: environment.machines.allMachines.map(\.id)) { _, _ in
      guard let controller else { return }
      if let canonical = canonicalProjectTarget(for: controller), !environment.machines.isSandbox(canonical.serverId) {
        selectedProjectId = canonical.isRunTargetPlaceholder ? nil : canonical.id
        environment.composerDefaults.rememberNewWorkspaceServer(
          serverId: canonical.serverId
        )
        Task {
          await controller.retarget(
            to: canonical,
            serverClient: environment.machines.client(for: canonical.serverId)
          )
        }
        return
      }
      controller.adoptServerClient(
        environment.machines.client(for: controller.project.serverId),
        forServer: controller.project.serverId
      )
      guard controller.preparationState == .failed || controller.harnesses.isEmpty
      else { return }
      Task { await controller.prepare() }
    }
    .focusedSceneValue(
      \.newChatComposerFocus,
      NewChatComposerFocus(
        focus: { focus.focusComposer() }
      ))
  }

  private var title: some View {
    Text("What should we build?")
      .font(.emptyStateTitle)
  }

  @ViewBuilder
  private func statusLabel(_ controller: SessionController) -> some View {
    if controller.isServerReady, let waitMessage = controller.serverWaitMessage {
      HStack {
        ShimmeringText(text: waitMessage)
        Spacer(minLength: 0)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
    }
  }

  private func setupFailureBanner(_ message: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.callout)
        .foregroundStyle(.red)
      Text(message)
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      if message == serverUnreachableErrorMessage {
        Button("Restart") { AppRelauncher.relaunch() }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Restart Codevisor and its server")
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackgroundColor))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Could not start chat. \(message)")
  }

  private func setUpController() {
    selectedProjectId = initialProjectTarget?.projectId
    let project =
      selectedProject
      ?? Project.runTargetPlaceholder(serverId: composerServerId)
    let controller: SessionController
    if let paneDraftId {
      guard let workspaceId = hostWorkspaceId else { return }
      controller = store.paneDraft(
        paneId: paneDraftId,
        project: project,
        preCreatedSession: preCreatedSession,
        workspaceId: workspaceId
      )
    } else {
      controller = store.draft(project: project)
    }
    if controller.project.id != project.id || controller.project.serverId != project.serverId {
      selectedProjectId =
        controller.project.isRunTargetPlaceholder
        ? nil : controller.project.id
    }
    if paneDraftId == nil,
      let initialProjectTarget,
      appliedInitialProjectTarget != initialProjectTarget
    {
      if let projectId = initialProjectTarget.projectId {
        if let explicit = environment.projectList.fleetActiveProjects.first(where: {
          $0.serverId == initialProjectTarget.serverId && $0.id == projectId
        }) {
          appliedInitialProjectTarget = initialProjectTarget
          if controller.project.serverId != explicit.serverId
            || controller.project.id != explicit.id
          {
            selectTargetProject(explicit, controller: controller)
          }
        }
      } else if let machine = environment.machines.machine(for: initialProjectTarget.serverId) {
        appliedInitialProjectTarget = initialProjectTarget
        selectTargetMachine(machine, controller: controller)
      }
    }
    installSendInterceptor(on: controller)
    controller.onScratchProjectCreated = { [weak projectList = environment.projectList] scratch in
      projectList?.registerServerProject(scratch)
    }
    let heldSend = sendLanding
    let heldSession = ObjectIdentifier(controller)
    heldSend.hold(heldSession)
    controller.onFirstSend = { [weak controller] submittedText in
      defer { heldSend.release(heldSession) }
      guard let controller else { return }
      let project = controller.project
      let title = Self.title(from: submittedText)
      let session: ChatSession
      if let preCreatedSession,
        let updated = environment.projectList.updateSessionForFirstSend(
          preCreatedSession,
          title: title,
          harnessId: controller.selectedHarnessId
        )
      {
        session = updated
      } else {
        let workspace = hostWorkspaceId.flatMap {
          environment.workspaces.workspace(id: $0)
        }
        session = environment.projectList.newSession(
          in: project,
          title: title,
          harnessId: controller.selectedHarnessId,
          worktreeName: workspace?.worktreeName ?? controller.worktreeName,
          cwd: workspace?.rootDirectory ?? controller.sessionCwdOverride,
          syncToServer: false
        )
      }
      controller.serverSession = session
      controller.onWorktreeCreated = { [weak projectList = environment.projectList, weak store = store] worktree in
        projectList?.setWorktree(
          name: worktree.name,
          cwd: worktree.path,
          for: session.id,
          serverId: session.serverId
        )
        store?.applyWorktree(worktree, toWorkspaceOf: session.id)
      }
      if let agentSessionId = controller.connectedAgentSessionId {
        environment.projectList.setAgentSessionId(
          agentSessionId,
          for: session.id,
          serverId: session.serverId
        )
      }
      controller.onAgentSessionCreated = { [weak projectList = environment.projectList] agentSessionId in
        projectList?.setAgentSessionId(
          agentSessionId,
          for: session.id,
          serverId: session.serverId
        )
      }
      controller.onSetupFailed = { [weak controller] in
        guard let controller else { return }
        controller.serverSession = nil
        controller.onAgentSessionCreated = nil
        let owningPaneId = store.paneDraftLocation(for: session)?.paneId
        if let failedPaneId = owningPaneId ?? paneDraftId {
          store.restorePaneDraftPersistence(
            controller,
            paneId: failedPaneId
          )
        } else {
          store.restoreDraftPersistence(controller)
        }
      }
      store.register(controller, for: session)
      if let paneDraftId, let onCreatedInPane {
        store.removePaneDraft(paneId: paneDraftId)
        onCreatedInPane(session)
      } else {
        let workspace = store.createWorkspace(for: session, project: project)
        controller.hostWorkspaceId = workspace.id
        environment.composerDefaults.performPersistenceBatch(
          flushImmediately: true
        ) {
          environment.composerDefaults.rememberNewWorkspaceProject(
            serverId: project.serverId,
            projectId: project.isScratch ? Project.runTargetPlaceholderID : project.id
          )
          if project.isGitRepository, !project.isScratch {
            environment.rememberSentRunLocation(
              newWorktree: controller.wantsNewWorktree,
              for: project
            )
          }
        }
        store.selectChat(session)
        selection = .session(serverId: session.serverId, id: session.id)
      }
    }
    self.controller = controller
    Task {
      await controller.prepare()
    }
  }

  private static func title(from prompt: String) -> String {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? "New session"
    if firstLine.count > 48 { return String(firstLine.prefix(48)) + "…" }
    return firstLine.isEmpty ? "New session" : firstLine
  }
}

#Preview {
  @Previewable @State var selection: SidebarSelection?
  let environment = AppEnvironment.preview()
  return NewChatView(
    store: SessionStore(environment: environment),
    selection: $selection,
    initialProjectTarget: nil
  )
  .environment(environment)
  .frame(width: 900, height: 640)
}

@MainActor
private final class NewChatSendLanding {
  var pageFrame: CGRect = .zero
  private var heldSession: ObjectIdentifier?

  func hold(_ session: ObjectIdentifier) {
    if let heldSession, heldSession != session {
      TranscriptSendStaging.shared.removeLandingProvider(for: heldSession, owner: self)
    }
    heldSession = session
    TranscriptSendStaging.shared.setLandingProvider(
      for: session,
      owner: self,
      holds: { [weak self] in self?.heldSession == session },
      landing: { [weak self] in self?.landing }
    )
  }

  func holds(_ session: ObjectIdentifier) -> Bool {
    heldSession == session
  }

  func release(_ session: ObjectIdentifier) {
    if heldSession == session { heldSession = nil }
    TranscriptSendStaging.shared.releaseHeldSend(session: session)
    TranscriptSendStaging.shared.removeLandingProvider(for: session, owner: self)
  }

  var landing: TranscriptSendLanding? {
    guard pageFrame.width > 0 else { return nil }
    let padding = VirtualizedTranscriptScrollView.horizontalPadding
    let rowWidth = min(VirtualizedTranscriptScrollView.maxRowWidth, max(1, pageFrame.width - padding * 2))
    let rowX = max(padding, (pageFrame.width - rowWidth) / 2)
    return TranscriptSendLanding(
      trailing: pageFrame.minX + rowX + rowWidth,
      top: pageFrame.minY + VirtualizedTranscriptScrollView.topPadding,
      maxBubbleWidth: rowWidth - 40
    )
  }
}
