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

struct NewChatView: View {
    @Environment(AppEnvironment.self) var environment
    @Environment(\.theme) private var theme
    let store: SessionStore
    @Binding var selection: SidebarSelection?
    var preferredProjectId: UUID?
    /// Set when the page was opened for a specific project (sidebar "+" /
    /// "New chat here"); nil for the generic new-chat entry. An explicit
    /// project moves a retained draft; an implicit one follows the draft.
    var explicitProjectId: UUID?
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

    @State private var controller: SessionController?
    @State var selectedProjectId: UUID?
    @State private var focus = TerminalFocusController()
    @State var addProjectFlow = AddProjectFlow()
    @State var managedProject: Project?
    @Namespace private var composerGlassNamespace
    /// Setup state for the no-projects panel. Owned here (not by the panel)
    /// because a clone registers its project immediately — the page must keep
    /// showing the panel with the clone as a selected row, exactly like
    /// onboarding, instead of flipping to the composer mid-setup.
    @State private var projectSetup = ProjectSetupModel()

    var projects: [Project] { environment.projectList.activeProjects }
    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId } ?? projects.first
    }
    private var setupIdentity: String {
        "\(environment.machines.selectedMachineId):\(preferredProjectId?.uuidString ?? "default")"
    }
    private var harnessCatalogRevision: UInt64 {
        environment.harnessCatalogRevision(for: environment.machines.selectedMachineId)
    }

    /// The setup panel shows while the machine has no projects, and stays up
    /// while the user has staged-but-unconfirmed work (a completed clone
    /// already counts as a project, but setup isn't done until confirmed).
    private var showsProjectSetup: Bool {
        projects.isEmpty || projectSetup.hasStagedWork
    }

    var body: some View {
        if paneDraftId == nil {
            // Page mode only: an embedded draft pane must not override the
            // workspace window's title.
            content.navigationTitle("New chat")
        } else {
            content
        }
    }

    private var content: some View {
        VStack {
            // 2:3 spacer split sits the composer slightly above true center.
            Spacer()
            Spacer()
            VStack(spacing: 22) {
                title
                if showsProjectSetup {
                    // Inline setup instead of pointing at the sidebar's "+":
                    // onboarding's project step, adapted to the selected
                    // machine. This is the first thing a user sees after
                    // adding a fresh (often headless remote) machine.
                    ProjectSetupPanel(model: projectSetup) { project in
                        projectSetup = ProjectSetupModel()
                        selectedProjectId = project.id
                        selection = .newChat(project.id)
                    }
                } else if let controller {
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
                                        projectPicker(controller)
                                        if liveProject(for: controller).isGitRepository {
                                            Divider()
                                                .frame(height: 14)
                                                .accessibilityHidden(true)
                                            runLocationPicker(controller)
                                        }
                                    }
                                    .font(.callout)
                                    .padding(.horizontal, 8)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Pinned to the pane's top edge as an overlay: appearing or
        // dismissing the update notice never shifts the composer's layout.
        .overlay(alignment: .top) {
            if let controller {
                Group {
                    if case let .failed(message) = controller.status {
                        setupFailureBanner(message)
                    } else {
                        HarnessUpdateBannerView(
                            controller: controller,
                            hasRunningChats: controller.activeHarnessId.map { harnessId in
                                store.hasActiveSessions(
                                    forHarness: harnessId,
                                    onServer: environment.machines.selectedMachineId
                                )
                            } ?? false
                        )
                    }
                }
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
        // Same add-project flow as the sidebar's +. On the page the fresh
        // project simply becomes the picker's selection.
        .addProjectFlow(addProjectFlow) { project in
            if let controller, showsRunPickers {
                selectTargetProject(project, controller: controller)
            } else {
                selectedProjectId = project.id
                selection = .newChat(project.id)
            }
        }
        .sheet(item: $managedProject) { project in
            ManageProjectSheet(
                project: project,
                client: environment.machines.client(for: project.serverId),
                didUpdate: { await environment.projectList.refreshFromServer() },
                onArchive: { archiveManagedProject(project, controller: controller) }
            )
        }
        // Stale-while-revalidate: the persisted project snapshot renders the
        // page immediately, then the server re-probes folder capabilities in
        // the background and publishes any changed Git status into this view.
        .task {
            await environment.projectList.refreshFromServer()
        }
        .task(id: setupIdentity) { setUpController() }
        // A machine's projects can arrive after this view's initial task has
        // already returned. Retry when the active project set changes so the
        // composer does not remain hidden after the first project appears.
        .onChange(of: projects.map(\.id)) { _, _ in
            // Not while setup is staging: a clone registers its project
            // immediately, and eagerly connecting an agent there would be
            // premature — the user may confirm with a different selection.
            guard controller == nil, !showsProjectSetup else { return }
            setUpController()
        }
        // Settings lives in a separate window, so this page can remain mounted
        // while sign-in changes a harness from unavailable to ready. Refetch
        // the live capabilities snapshot when that machine's catalog changes.
        .onChange(of: harnessCatalogRevision) { _, _ in
            guard let controller else { return }
            Task { await controller.refreshHarnessCapabilities() }
        }
        // Update knowledge is fetched separately from the picker's plain
        // list so the composer stays snappy; the update banner reads this.
        .task(id: harnessCatalogRevision) {
            await environment.refreshHarnessLifecycle(
                for: environment.machines.selectedMachineId
            )
        }
        .focusedSceneValue(
            \.newChatComposerFocus,
            NewChatComposerFocus(
                focus: { focus.focusComposer() }
            ))
    }

    // MARK: - Title

    @ViewBuilder
    private var title: some View {
        if showsProjectSetup {
            Text("Add a project to start")
                .font(.emptyStateTitle)
        } else {
            Text("What should we build?")
                .font(.emptyStateTitle)
        }
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
        selectedProjectId = preferredProjectId ?? projects.first?.id
        guard let project = selectedProject else { return }
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
        if controller.project.id != project.id {
            // Follow the draft's own project so the title matches the
            // composer state the user left.
            selectedProjectId = controller.project.id
        }
        // An explicit entry point ("New chat here") re-points even a retained
        // draft at that project; the generic entry follows the draft.
        if paneDraftId == nil,
            let explicitProjectId,
            controller.project.id != explicitProjectId,
            let explicit = projects.first(where: { $0.id == explicitProjectId })
        {
            selectTargetProject(explicit, controller: controller)
        }
        controller.onFirstSend = { [weak controller] in
            guard let controller else { return }
            let project = controller.project
            let title = Self.title(from: controller.composerText)
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
                if let paneDraftId {
                    store.restorePaneDraftPersistence(
                        controller,
                        paneId: paneDraftId
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
                    environment.composerDefaults.rememberNewWorkspaceProject(
                        serverId: project.serverId,
                        projectId: project.id
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
                Task { @MainActor [weak controller] in
                    // Give SwiftUI one commit with the new sidebar identity
                    // before mounting the substantially heavier workspace
                    // destination. This is one run-loop turn, not a guessed
                    // animation delay.
                    await Task.yield()
                    guard controller?.serverSession?.id == session.id else { return }
                    selection = .session(serverId: session.serverId, id: session.id)
                }
            }
        }
        self.controller = controller
        Task {
            await controller.prepare()
            if !AppPreview.isRunning,
                !controller.showsNewChatAfterSetupFailure
            {
                await controller.connectIfNeeded()
            }
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
        preferredProjectId: nil
    )
    .environment(environment)
    .frame(width: 900, height: 640)
}
