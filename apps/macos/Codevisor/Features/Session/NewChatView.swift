import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore

/// The new-chat page: a centered "What should we build in <project>?" title with
/// an inline project dropdown, and the composer. The session is created only
/// when the user sends.
struct NewChatView: View {
    @Environment(AppEnvironment.self) private var environment
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
    /// Fired when a failed first-send setup deletes the session, so the
    /// hosting pane can drop its (now dangling) session reference.
    var onSetupFailedInPane: (() -> Void)? = nil

    @State private var controller: SessionController?
    @State private var selectedProjectId: UUID?
    @State private var runInWorktree = false
    @State private var focus = TerminalFocusController()
    @State private var addProjectFlow = AddProjectFlow()
    @Namespace private var composerGlassNamespace
    /// Setup state for the no-projects panel. Owned here (not by the panel)
    /// because a clone registers its project immediately — the page must keep
    /// showing the panel with the clone as a selected row, exactly like
    /// onboarding, instead of flipping to the composer mid-setup.
    @State private var projectSetup = ProjectSetupModel()

    private var projects: [Project] { environment.projectList.activeProjects }
    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId } ?? projects.first
    }
    private var setupIdentity: String {
        "\(environment.machines.selectedMachineId):\(preferredProjectId?.uuidString ?? "default")"
    }
    private var harnessCatalogRevision: UInt64 {
        environment.harnessCatalogRevision(for: environment.machines.selectedMachineId)
    }

    /// Worktrees only make sense when the project folder is a git repository
    /// (as probed by the session's server).
    private var worktreeAvailable: Bool {
        selectedProject?.isGitRepository ?? false
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
                                    showsHarnessPicker: false,
                                    onTextViewReady: { textView in
                                        focus.composerTextView = textView
                                        // The text view isn't attached to a window yet during
                                        // makeNSView; focus once it is.
                                        DispatchQueue.main.async { focus.focusComposer() }
                                    },
                                    glassNamespace: composerGlassNamespace
                                )
                                HStack(spacing: 4) {
                                    if controller.canChooseHarness {
                                        HarnessPickerMenu(controller: controller)
                                        Divider()
                                            .frame(height: 14)
                                            .accessibilityHidden(true)
                                    }
                                    // In-pane drafts belong to their
                                    // workspace's project — no picker.
                                    if paneDraftId == nil {
                                        workspacePicker
                                        Divider()
                                            .frame(height: 14)
                                            .accessibilityHidden(true)
                                    }
                                    runLocationPicker(controller)
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
        .attachmentDropTarget(controller)
        // Same add-project flow as the sidebar's +.
        .addProjectFlow(addProjectFlow) { project in
            selectedProjectId = project.id
            selection = .newChat(project.id)
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
        .focusedSceneValue(\.newChatComposerFocus, NewChatComposerFocus(
            focus: { focus.focusComposer() }
        ))
    }

    // MARK: - Title

    @ViewBuilder
    private var title: some View {
        if showsProjectSetup {
            Text("Add a project to start")
                .font(.system(size: 26, weight: .semibold))
        } else {
            Text("What should we build?")
                .font(.system(size: 26, weight: .semibold))
        }
    }

    private var workspacePicker: some View {
        Menu {
            ForEach(projects) { project in
                // Toggle for the native selected checkmark; MenuSymbolIcon
                // because AppKit menus drop plain SF Symbol images.
                Toggle(isOn: Binding(
                    get: { project.id == selectedProject?.id },
                    set: { isOn in
                        guard isOn else { return }
                        selectedProjectId = project.id
                        // Worktree choice doesn't carry across projects that can't support it.
                        if !(project.isGitRepository) {
                            runInWorktree = false
                            controller?.wantsNewWorktree = false
                        }
                        if let controller { Task { await controller.selectProject(project) } }
                        // Keep the cached selection responsive, then re-probe
                        // project metadata independently in the background.
                        Task {
                            await environment.projectList.refreshFromServer()
                        }
                    }
                )) {
                    Label {
                        Text(project.name)
                    } icon: {
                        // Same filled variant the sidebar rows use.
                        MenuSymbolIcon(systemName: FilledSymbol.preferred(project.symbolName))
                    }
                }
            }
            Divider()
            Button {
                addProjectFlow.begin()
            } label: {
                Label {
                    Text("New project…")
                } icon: {
                    MenuSymbolIcon(systemName: "folder.badge.plus")
                }
            }
        } label: {
            PickerChip(text: selectedProject?.name ?? "Workspace") {
                Image(
                    systemName: selectedProject.map {
                        FilledSymbol.preferred($0.symbolName)
                    } ?? "folder.fill"
                )
                .font(.system(size: 12))
            }
        }
        .menuStyle(.button)
        .buttonStyle(HoverIconButtonStyle(shape: .chip))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose workspace")
    }

    /// "Workspace directory" vs "New worktree" for where the chat runs (the
    /// chosen directory becomes the workspace's root). Worktree is only
    /// offered for git projects; the worktree itself is created on the first
    /// send.
    @ViewBuilder
    private func runLocationPicker(_ controller: SessionController) -> some View {
        Menu {
            Toggle(isOn: Binding(
                get: { !runInWorktree },
                set: { isOn in
                    guard isOn, runInWorktree else { return }
                    runInWorktree = false
                    controller.wantsNewWorktree = false
                    // Re-establish the eager connection in the project folder.
                    Task { await controller.reconnect() }
                }
            )) {
                Label {
                    Text("Workspace directory")
                } icon: {
                    MenuSymbolIcon(systemName: "folder.fill")
                }
            }
            Toggle(isOn: Binding(
                get: { runInWorktree },
                set: { isOn in
                    guard isOn, !runInWorktree else { return }
                    runInWorktree = true
                    controller.wantsNewWorktree = true
                    // Drop any eager connection pinned to the project folder; the
                    // agent reconnects in the worktree on first send.
                    Task { await controller.reconnect() }
                }
            )) {
                Label {
                    Text("New worktree")
                } icon: {
                    MenuSymbolIcon(systemName: "arrow.triangle.branch")
                }
            }
            .disabled(!worktreeAvailable)
        } label: {
            PickerChip(text: runInWorktree ? "New worktree" : "Workspace directory") {
                Image(systemName: runInWorktree ? "arrow.triangle.branch" : "folder.fill")
                    .font(.system(size: 12))
            }
        }
        .menuStyle(.button)
        .buttonStyle(HoverIconButtonStyle(shape: .chip))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(
            worktreeAvailable
                ? "Where this chat's commands run"
                : "Worktrees need the project folder to be a git repository"
        )
    }

    /// Inline error for a failed session start. This page has no transcript
    /// yet, so directly beneath the composer IS adjacent to where the failure
    /// happened (HIG: show errors near their source).
    @ViewBuilder
    private func statusLabel(_ controller: SessionController) -> some View {
        if case let .failed(message) = controller.status {
            HStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(theme.statusError)
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
            .background(
                RoundedRectangle(cornerRadius: 8).fill(theme.statusError.opacity(0.1))
            )
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Setup

    private func setUpController() {
        selectedProjectId = preferredProjectId ?? projects.first?.id
        guard let project = selectedProject else { return }
        let controller = paneDraftId.map { store.paneDraft(paneId: $0, project: project) }
            ?? store.draft(project: project)
        if controller.project.id != project.id {
            let draftProjectExists = projects.contains { $0.id == controller.project.id }
            if explicitProjectId == project.id || !draftProjectExists {
                // Opened explicitly for this project (or the draft's project is
                // gone): move the draft here, keeping its text/attachments.
                Task { await controller.selectProject(project) }
            } else {
                // Generic entry: follow the draft's own project so the title
                // and pickers match the composer state the user left.
                selectedProjectId = controller.project.id
            }
        }
        // Restore the draft's worktree choice (remembered defaults or an
        // earlier visit), clamped to projects that can support it.
        if !worktreeAvailable { controller.wantsNewWorktree = false }
        runInWorktree = controller.wantsNewWorktree
        controller.onFirstSend = { [weak controller] in
            guard let controller, let project = selectedProject else { return }
            let title = Self.title(from: controller.composerText)
            let session: ChatSession
            if let preCreatedSession,
               let updated = environment.projectList.updateSessionForFirstSend(
                   preCreatedSession,
                   title: title,
                   harnessId: controller.selectedHarnessId,
                   worktreeName: controller.worktreeName,
                   cwd: controller.sessionCwdOverride
               ) {
                // The record already exists (eager creation put it in the
                // sidebar); first send fills in what's now known.
                session = updated
            } else {
                session = environment.projectList.newSession(
                    in: project,
                    title: title,
                    harnessId: controller.selectedHarnessId,
                    worktreeName: controller.worktreeName,
                    cwd: controller.sessionCwdOverride,
                    syncToServer: false
                )
            }
            controller.serverSession = session
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
            // The session record is registered before the worktree exists (the
            // page opens while setup streams progress); patch in the worktree
            // name/cwd once the server has materialized it.
            controller.onWorktreeCreated = { [weak projectList = environment.projectList] worktree in
                projectList?.setWorktree(
                    name: worktree.name,
                    cwd: worktree.path,
                    for: session.id,
                    serverId: session.serverId
                )
            }
            // If worktree setup or the agent start fails, undo the promotion:
            // delete the just-created session record (local + server), demote
            // the controller back to the draft slot, and reopen the new-chat
            // page — its status label shows the failure.
            controller.onSetupFailed = { [weak controller, weak projectList = environment.projectList] in
                guard let controller else { return }
                projectList?.deleteSession(session)
                controller.serverSession = nil
                controller.onAgentSessionCreated = nil
                controller.onWorktreeCreated = nil
                if let paneDraftId {
                    // The pane stays a draft; its composer (with the failed
                    // send's status) returns to the pane's draft slot, and
                    // the pane drops its reference to the deleted session.
                    store.demoteToPaneDraft(controller, session: session, paneId: paneDraftId)
                    onSetupFailedInPane?()
                } else {
                    store.demote(controller, session: session)
                    selection = .newChat(project.id)
                }
            }
            store.register(controller, for: session)
            if let paneDraftId, let onCreatedInPane {
                // In-pane draft: bind the pane to its new session in place —
                // no navigation, the workspace stays exactly where it is.
                store.removePaneDraft(paneId: paneDraftId)
                onCreatedInPane(session)
            } else {
                selection = .session(serverId: session.serverId, id: session.id)
            }
        }
        self.controller = controller
        Task {
            await controller.prepare()
            if !AppPreview.isRunning { await controller.connectIfNeeded() }
        }
    }

    private static func title(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? "New session"
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : (firstLine.isEmpty ? "New session" : firstLine)
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
