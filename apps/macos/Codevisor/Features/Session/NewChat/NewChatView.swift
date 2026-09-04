import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CodevisorCore
import CodevisorUI

/// The new-chat page: a centered "What should we build in <project>?" title with
/// an inline project dropdown, and the composer. The session is created only
/// when the user sends.
/// Surfaces the backing NSView of the new-chat pane's background so it can
/// register as a whitespace-click zone with the workspace's focus
/// controller (`handleTranscriptClick` needs an AppKit view for geometry).
private struct PaneClickZoneCapture: NSViewRepresentable {
  let onReady: (NSView) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { onReady(view) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Keeps a short project reconciliation invisible. If it outlives the normal
/// 500 ms grace period, the blank surface becomes an explicit loading state.
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

struct NewProjectTarget: Identifiable {
  let serverId: String
  var id: String { serverId }
}

struct NewChatView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.theme) private var theme
  let store: SessionStore
  @Binding var selection: SidebarSelection?
  /// Set when navigation opened the page for a specific machine/project.
  /// It initializes the retained draft once; after that, the run-target
  /// pickers own the draft and navigation must not reassert this value.
  var initialProjectTarget: NewChatTarget?
  /// In-pane draft mode: the id of the DRAFT CHAT PANE hosting this
  /// composer (inside a workspace). The created session binds to the pane
  /// via `onCreatedInPane` instead of navigating, and the composer uses a
  /// per-pane draft controller rather than the per-server page draft.
  var paneDraftId: UUID? = nil
  var onCreatedInPane: ((ChatSession) -> Void)? = nil
  /// The pane's session ALREADY EXISTS (created eagerly so the sidebar
  /// lists it before the first message): first send fills in its details
  /// (title, harness, worktree/cwd) instead of creating a new record.
  var preCreatedSession: ChatSession? = nil
  /// The WORKSPACE's shared focus controller (pane mode only). The
  /// composer registers under the pre-created chat's id so pane/tab
  /// clicks and the container's open sequence can focus it exactly like
  /// a started chat's composer.
  var paneFocus: TerminalFocusController? = nil
  /// The hosting workspace (pane mode): supplies the workspace's one
  /// working directory (worktree or project root), stamped onto the
  /// session at first send.
  var hostWorkspaceId: UUID? = nil
  /// The one-shot handoff from onboarding waits for the authoritative
  /// project refresh before deciding between setup and the composer.
  var requiresInitialProjectResolution = false
  var onInitialProjectResolutionCompleted: (() -> Void)? = nil

  @State var controller: SessionController?
  @State var selectedProjectId: UUID?
  @State private var appliedInitialProjectTarget: NewChatTarget?
  @State private var focus = TerminalFocusController()
  @State var newProjectTarget: NewProjectTarget?
  @State var managedProject: Project?
  /// Which run picker chip the pointer is over; its neighbouring dividers
  /// hide so the hover capsule never butts against a hairline.
  @State var hoveredRunPicker: RunPicker?
  /// Set when the user escaped a blocked remote target from the
  /// availability screen. Outranks navigation's initial target and the
  /// remembered machine so the page re-points before a draft exists.
  @State var composerMachineFallbackId: String?
  @Namespace private var composerGlassNamespace
  @Environment(\.openSettings) var openSettings

  private var selectedProject: Project? {
    projects.first { $0.id == selectedProjectId } ?? projects.first
  }

  var body: some View {
    if paneDraftId == nil, theme.isSystem {
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
        // 2:3 spacer split sits the composer slightly above true center.
        Spacer()
        Spacer()
        VStack(spacing: 22) {
          title
          if let controller {
            VStack(alignment: .leading, spacing: 8) {
              GlassEffectContainer(spacing: ComposerGlassStyle.clusterSpacing) {
                VStack(alignment: .leading, spacing: ComposerGlassStyle.clusterSpacing) {
                  ComposerCard(
                    controller: controller,
                    placeholder: "Do anything",
                    onTextViewReady: { textView in
                      focus.composerTextView = textView
                      if let paneFocus, let chatId = preCreatedSession?.id {
                        // REGISTRATION ONLY, like ChatScreen:
                        // the container's keyed focus request
                        // (open sequence, pane/tab clicks)
                        // applies the moment this lands.
                        paneFocus.registerComposer(textView, forChat: chatId)
                      } else {
                        // Standalone page: the text view isn't
                        // attached to a window yet during
                        // makeNSView; focus once it is.
                        DispatchQueue.main.async { focus.focusComposer() }
                      }
                    },
                    focus: paneFocus ?? focus,
                    focusChatId: preCreatedSession?.id,
                    glassNamespace: composerGlassNamespace
                  )
                  if showsRunPickers {
                    HStack(spacing: 4) {
                      if showsMachinePicker {
                        machinePicker(controller)
                        runPickerDivider(between: .machine, and: .project)
                      }
                      projectPicker(controller)
                      if liveProject(for: controller).isGitRepository {
                        runPickerDivider(between: .project, and: .location)
                        runLocationPicker(controller)
                      }
                    }
                    .font(.callout)
                    // The chips' hover capsules bleed 5pt
                    // sideways and 3pt vertically past their
                    // layout (HoverIconButtonStyle .chip), so
                    // 6/4 leaves an even 1pt ring between the
                    // highlight and the glass pill's edge.
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.contentBackground)
    // Pinned to the pane's top edge as an overlay: appearing or
    // dismissing the notice never shifts the composer's layout. Update
    // notices moved to the update center; only setup failures remain
    // contextual here.
    .overlay(alignment: .top) {
      if let controller, case let .failed(message) = controller.status {
        setupFailureBanner(message)
          .frame(maxWidth: 720)
          .padding(.horizontal, 16)
          .padding(.top, 12)
      }
    }
    // The whole pane is a click-to-focus zone, exactly like a started
    // chat's transcript: whitespace clicks land in the composer (the
    // pane's one input) unless the click claimed focus itself.
    .background {
      if let paneFocus, let chatId = preCreatedSession?.id {
        PaneClickZoneCapture { view in
          paneFocus.registerTranscript(view, forChat: chatId)
        }
      }
    }
    .attachmentDropTarget(controller)
    .sheet(item: $newProjectTarget) { target in
      NewProjectSheet(serverId: target.serverId) { project in
        if let controller, showsRunPickers {
          selectTargetProject(project, controller: controller)
        } else {
          selectedProjectId = project.id
          selection = .newChat(NewChatTarget(project))
        }
      }
    }
    // "No project" is a stable choice, so a project arriving later never
    // hijacks the draft; only a missing controller gets set up here.
    .onChange(of: projects.map(\.id)) { _, _ in
      if controller == nil, !requiresInitialProjectResolution {
        setUpController()
      }
    }
    .sheet(item: $managedProject) { project in
      ManageProjectSheet(
        project: project,
        client: environment.machines.client(for: project.serverId),
        didUpdate: {
          await environment.projectList.refreshFromServer(
            serverId: project.serverId,
            client: environment.machines.client(for: project.serverId)
          )
        },
        onArchive: { archiveManagedProject(project, controller: controller) }
      )
    }
    // Established installs stay stale-while-revalidate. The one-shot
    // onboarding handoff keeps its loading surface mounted until this
    // same authoritative refresh finishes.
    .task(id: composerServerId) {
      await environment.projectList.refreshFromServer(
        serverId: composerServerId,
        client: environment.machines.client(for: composerServerId)
      )
      if requiresInitialProjectResolution {
        onInitialProjectResolutionCompleted?()
      }
    }
    .task(id: setupIdentity) {
      guard !requiresInitialProjectResolution else { return }
      setUpController()
    }
    // Settings lives in a separate window, so this page can remain mounted
    // while sign-in changes a harness from unavailable to ready. Refetch
    // the live capabilities snapshot when that machine's catalog changes.
    .onChange(of: harnessCatalogRevision) { _, _ in
      guard let controller else { return }
      // Mark the mounted draft stale synchronously, but retain its usable
      // picker values until the replacement arrives.
      controller.invalidateHarnessCapabilities()
      Task { await controller.refreshHarnessCapabilities() }
    }
    // A draft restored onto a cloud machine can mount BEFORE the cloud
    // relay is routable — its capability fetch fails (never silently
    // answering as another machine). Re-resolve the client and retry
    // when the reachable machine set changes.
    .onChange(of: environment.machines.allMachines.map(\.id)) { _, _ in
      guard let controller else { return }
      if let canonical = canonicalProjectTarget(for: controller) {
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
        environment.machines.client(for: controller.project.serverId)
      )
      guard controller.preparationState == .failed || controller.harnesses.isEmpty
      else { return }
      Task { await controller.prepare() }
    }
    // A route flip (direct ↔ relay) doesn't change the machine set, so
    // watch it separately: the draft's next send must ride the new route.
    .onChange(of: routeForDraftMachine) { _, _ in
      guard let controller else { return }
      controller.adoptServerClient(
        environment.machines.client(for: controller.project.serverId)
      )
    }
    // Update knowledge is fetched separately from the picker's plain
    // list so the composer stays snappy; the update banner reads this.
    .task(id: harnessCatalogRevision) {
      await environment.refreshHarnessLifecycle(
        for: composerServerId
      )
    }
    .focusedSceneValue(
      \.newChatComposerFocus,
      NewChatComposerFocus(
        focus: { focus.focusComposer() }
      ))
  }

  // MARK: - Title

  private var title: some View {
    Text("What should we build?")
      .font(.emptyStateTitle)
  }

  /// A rebooting server remains a calm loading state beneath the composer.
  /// Terminal setup errors use the pane's established top-banner position.
  @ViewBuilder
  private func statusLabel(_ controller: SessionController) -> some View {
    if let waitMessage = controller.serverWaitMessage {
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
        .foregroundStyle(theme.statusError)
      Text(message)
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      // Relaunching the app restarts the managed server too.
      if message == serverUnreachableErrorMessage {
        Button("Restart") { AppRelauncher.relaunch() }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Restart Codevisor and its server")
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
    .themedCardShadow(theme)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Could not start chat. \(message)")
  }

  // MARK: - Setup

  private func setUpController() {
    // Only an explicit entry point picks a project up front; otherwise the
    // draft store restores the remembered one and a fresh draft starts
    // with no project at all.
    selectedProjectId = initialProjectTarget?.projectId
    let project =
      selectedProject
      ?? Project.runTargetPlaceholder(serverId: composerServerId)
    // Keep the original draft controller path: it owns both the complete
    // per-composer snapshot and its correctly-scoped composer defaults.
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
      // Follow the draft's own project so the title matches the
      // composer state the user left.
      selectedProjectId =
        controller.project.isRunTargetPlaceholder
        ? nil : controller.project.id
    }
    // An explicit entry point ("New chat here") initializes even a
    // retained draft, but only once for this navigation target. Machine
    // and project picker actions after mount own the draft and must not be
    // undone when setup-related tasks re-evaluate.
    if paneDraftId == nil,
      let initialProjectTarget,
      appliedInitialProjectTarget != initialProjectTarget,
      let explicit = environment.projectList.fleetActiveProjects.first(where: {
        $0.serverId == initialProjectTarget.serverId
          && $0.id == initialProjectTarget.projectId
      })
    {
      appliedInitialProjectTarget = initialProjectTarget
      if controller.project.serverId != explicit.serverId
        || controller.project.id != explicit.id
      {
        selectTargetProject(explicit, controller: controller)
      }
    }
    controller.onScratchProjectCreated = { [weak projectList = environment.projectList] scratch in
      projectList?.registerServerProject(scratch)
    }
    controller.onFirstSend = { [weak controller] submittedText in
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
        // The record already exists (eager creation put it in the
        // sidebar, already stamped with the workspace's directory);
        // first send fills in what's now known.
        session = updated
      } else {
        // Page mode: the session is born in the picked project. A
        // worktree draft has no directory yet — the worktree
        // materializes right after this and lands on the records via
        // onWorktreeCreated below; the workspace inherits it too.
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
      controller.onWorktreeCreated = { [weak projectList = environment.projectList, weak store] worktree in
        projectList?.setWorktree(
          name: worktree.name,
          cwd: worktree.path,
          for: session.id,
          serverId: session.serverId
        )
        store?.applyWorktree(worktree, toWorkspaceOf: session.id)
      }
      // The eager connection may already hold an agent session id; persist
      // it, and capture any future-created id too.
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
      // Keep the session/workspace, but put this same controller back
      // behind the original draft persistence hooks. The restored text,
      // attachments, harness/config, run context, and goal state then
      // survive navigation and relaunch exactly as they did before.
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
        // In-pane draft: bind the pane to its new session in place —
        // no navigation, the workspace stays exactly where it is.
        store.removePaneDraft(paneId: paneDraftId)
        onCreatedInPane(session)
      } else {
        // The workspace materializes AROUND the sent chat: rooted in
        // the picked directory, fixed for every tab it ever hosts.
        let workspace = store.createWorkspace(for: session, project: project)
        // Persist the new-workspace choices and the concrete
        // workspace inheritance profile as one latest-value snapshot.
        // The encoder/SQLite work stays on the shared utility queue.
        environment.composerDefaults.performPersistenceBatch(
          flushImmediately: true
        ) {
          // A scratch folder is single-use; remember the CHOICE of no
          // project rather than the folder it happened to get.
          environment.composerDefaults.rememberNewWorkspaceProject(
            serverId: project.serverId,
            projectId: project.isScratch ? Project.runTargetPlaceholderID : project.id
          )
          environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
            serverId: project.serverId,
            createsWorktree: controller.wantsNewWorktree
          )
          controller.rememberCurrentComposerConfiguration()
          controller.moveComposerDefaults(
            to: .workspace(id: workspace.id, serverId: session.serverId)
          )
        }
        // Select the locally complete workspace in this send turn.
        // Remote setup continues after this callback and must not
        // delay workspace presentation.
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
    return firstLine.count > 48
      ? String(firstLine.prefix(48)) + "…" : (firstLine.isEmpty ? "New session" : firstLine)
  }
}

/// A simple line-wrapping layout: places subviews left-to-right, breaking onto a
/// new line when the next subview won't fit the proposed width. Each row is
/// centered (or leading/trailing) and its subviews vertically centered within
/// the row's height. Used by the new-chat title so a mix of word Texts and an
/// inline picker chip flow like a normal wrapping paragraph.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6
  var lineSpacing: CGFloat = 6
  var alignment: HorizontalAlignment = .center

  private struct Row {
    var items: [(index: Int, size: CGSize)] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let projected = current.items.isEmpty ? size.width : current.width + spacing + size.width
      if !current.items.isEmpty, projected > maxWidth {
        rows.append(current)
        current = Row()
      }
      current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.items.append((index, size))
    }
    if !current.items.isEmpty { rows.append(current) }
    return rows
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
    let width = proposal.width ?? (rows.map(\.width).max() ?? 0)
    let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
    let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
    var y = bounds.minY
    for row in rows {
      var x: CGFloat
      switch alignment {
      case .trailing: x = bounds.maxX - row.width
      case .leading: x = bounds.minX
      default: x = bounds.minX + (bounds.width - row.width) / 2
      }
      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
          proposal: ProposedViewSize(item.size)
        )
        x += item.size.width + spacing
      }
      y += row.height + lineSpacing
    }
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
