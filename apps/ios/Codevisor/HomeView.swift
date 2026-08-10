import CodevisorCore
import CodevisorUI
import SwiftUI

/// How the workspace list groups chats — the same organization options as the
/// macOS sidebar.
private enum HomeOrganization: String, CaseIterable {
    case compact
    case byWorkspace
    case byProject

    var title: String {
        switch self {
        case .compact: "Agents"
        case .byWorkspace: "Workspaces"
        case .byProject: "Projects"
        }
    }
}

/// Every destination in Home's authoritative navigation stack. New Chat is
/// deliberately absent: it is a real modal sheet until its first send creates
/// a workspace, at which point that workspace is mounted here.
private enum HomeRoute: Hashable {
    /// A workspace-row tap leaves `preferredChatSessionId` nil and restores
    /// the workspace's selected tab. An agent-row tap supplies the chat id so
    /// that chat always wins over a previously selected terminal.
    case workspace(workspaceId: UUID, anchorSessionId: UUID, preferredChatSessionId: UUID?)
}

private struct HomeWorkspaceListItem: Identifiable {
    let workspace: Workspace
    let sessions: [ChatSession]
    let primarySession: ChatSession?
    let project: Project?

    var id: UUID { workspace.id }
}

/// State shared across the native New Chat sheet and the workspace mounted
/// beneath it during first-send promotion. Keeping the durable controller in
/// `ChatControllerCache` and the handoff state here means neither presentation
/// container has to masquerade as the other.
@MainActor @Observable
private final class NewChatFlow: Identifiable {
    let id = UUID()
    var composerFocusRequest: UUID? = UUID()
    var sessionId: UUID?
    var isWorkspaceReady = false
    var isSheetExpanded = false

    func consumeFocusRequest(_ request: UUID) {
        guard composerFocusRequest == request else { return }
        composerFocusRequest = nil
    }
}

/// Ordering, matching the macOS sidebar: manual (drag), priority + recency,
/// or creation time.
private enum HomeOrder: String, CaseIterable {
    case none
    case updated
    case created

    var title: String {
        switch self {
        case .none: "None"
        case .updated: "Last updated"
        case .created: "Created"
        }
    }
}

/// The workspaces navigation screen: every workspace on the paired machine,
/// organized and ordered like the macOS sidebar, with settings at the top
/// left, the organize menu at the top right, and a fixed compose button at
/// the bottom trailing edge.
struct HomeView: View {
    private static let newChatTransitionID = "home-new-chat"
    /// Use the system's maximum-height sheet from the first frame. Its inset
    /// top edge, corners, backdrop, safe areas, and keyboard coordination all
    /// remain presentation-controller owned.
    private static let newChatComposeDetent = PresentationDetent.large

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ClientPreference("sidebar.organization", default: HomeOrganization.compact.rawValue)
    private var organizationRaw
    @ClientPreference("sidebar.order", default: HomeOrder.updated.rawValue)
    private var orderRaw
    @ClientPreference("sidebar.manualSessionOrder", default: "")
    private var manualSessionOrder
    @ClientPreference("sidebar.expandedProjects", default: "")
    private var expandedProjectsRaw
    @ClientPreference("sidebar.expandedWorkspaces", default: "")
    private var expandedWorkspacesRaw
    @ClientPreference("ios.onboarding.dismissed", default: false)
    private var onboardingDismissed
    @State private var onboardingStart = OnboardingView.Step.welcome
    // Bootstrap adds the dev machine a beat after first render; the grace
    // period keeps onboarding from flashing over an already-paired install.
    @State private var readyForOnboarding = false
    @State private var isShowingSettings = false
    @State private var isManagingMachines = false
    @State private var newChatFlow: NewChatFlow?
    @State private var newChatSheetPath = NavigationPath()
    @State private var newChatDetent = Self.newChatComposeDetent
    // A typed path lets Home identify the workspace currently presented and
    // pop it when a remote server refresh archives that chat.
    @State private var path: [HomeRoute] = []
    @State private var pendingDeeplink: MachineDeeplink?
    @State private var deeplinkError: String?
    @State private var isPointerInsideSidebar = false
    @GestureState private var isTouchingSidebar = false
    @State private var deferredSessionOrder = InteractionDeferredOrder<UUID>()
    /// Non-nil while a burst of automatic reorders is settling (the deferred
    /// order is locked without the user touching or hovering the list).
    @State private var reorderSettleHoldStart: Date?
    @State private var reorderSettleTask: Task<Void, Never>?
    /// The repository is deliberately non-observable. Bump this after a
    /// workspace backfill or local layout mutation so the hierarchy re-reads.
    @State private var workspaceRevision = 0
    @Namespace private var newChatTransition

    private var organization: HomeOrganization {
        HomeOrganization(rawValue: organizationRaw) ?? .compact
    }

    private var order: HomeOrder {
        HomeOrder(rawValue: orderRaw) ?? .updated
    }

    private var machines: MachineController { environment.machines }
    private var projectList: ProjectListModel { environment.projectList }

    private var hasRemoteMachines: Bool {
        machines.allMachines.contains { !$0.isLocal }
    }

    /// Onboarding presents itself whenever no machine is paired. There is no
    /// in-flow skip (the app is useless without a machine); the dismissed
    /// flag only records programmatic closes — e.g. pairing while the cover
    /// is up — and the empty state re-arms it.
    private var showsOnboarding: Binding<Bool> {
        Binding(
            get: { readyForOnboarding && !onboardingDismissed && !hasRemoteMachines },
            set: { if !$0 { onboardingDismissed = true } }
        )
    }

    /// Active chats on the selected machine in the order the sort wants
    /// right now, before the interaction/settle holds are applied. Watched
    /// separately from `visibleSessions` to coalesce bursts of automatic
    /// reorders (the held, displayed order does not change while locked).
    private var desiredVisibleSessions: [ChatSession] {
        let sessions = projectList.sessions
            .filter { $0.serverId == machines.selectedMachineId && !$0.isArchived }
        switch order {
        case .updated:
            // Priority first (errors, waiting, unread), then recency — the
            // macOS sidebar's default.
            return sessions.sorted { lhs, rhs in
                let lp = priority(for: lhs)
                let rp = priority(for: rhs)
                if lp != rp { return lp < rp }
                return lhs.sidebarStateChangedAt > rhs.sidebarStateChangedAt
            }
        case .created:
            return sessions.sorted { $0.createdAt > $1.createdAt }
        case .none:
            let ordered = manualSessionOrder
                .split(separator: "\n")
                .compactMap { UUID(uuidString: String($0)) }
            var index: [UUID: Int] = [:]
            for (position, id) in ordered.enumerated() { index[id] = position }
            return sessions.sorted { lhs, rhs in
                let li = index[lhs.id] ?? Int.max
                let ri = index[rhs.id] ?? Int.max
                if li != ri { return li < ri }
                return lhs.sidebarStateChangedAt > rhs.sidebarStateChangedAt
            }
        }
    }

    /// Active chats on the selected machine, in the chosen order.
    private var visibleSessions: [ChatSession] {
        let desired = desiredVisibleSessions
        guard order != .none else { return desired }
        return deferredSessionOrder.applying(to: desired, id: \.id)
    }

    /// Same workspace projection as the macOS sidebar: sessions follow their
    /// workspace pane order, and workspaces follow their primary session's
    /// current navigation order.
    private var workspaceItems: [HomeWorkspaceListItem] {
        _ = workspaceRevision
        _ = environment.workspaceSync.revision
        let serverId = machines.selectedMachineId
        let sessionRank = Dictionary(
            visibleSessions.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: min
        )
        let sessionsById = Dictionary(
            visibleSessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return environment.workspaces.loadAll()
            .filter { $0.serverId == serverId && !$0.isArchived }
            .map { workspace -> (HomeWorkspaceListItem, Int, Date) in
                // Honor the repository's grow-only routing index when healing
                // layouts from older iOS builds. A superseded automatic
                // one-chat workspace can remain on disk, but must not produce
                // a duplicate navigation row after its chat moves home.
                let sessions = workspace.chatSessionIds.compactMap { id -> ChatSession? in
                    guard environment.workspaces.workspaceId(forSession: id) == workspace.id else {
                        return nil
                    }
                    return sessionsById[id]
                }
                let primary = sessions.first
                let routingSession = primary ?? visibleSessions.first {
                    environment.workspaces.workspaceId(forSession: $0.id) == workspace.id
                }
                let project = projectList.projects.first {
                    $0.serverId == serverId && $0.id == workspace.projectId
                }
                return (
                    HomeWorkspaceListItem(
                        workspace: workspace,
                        sessions: sessions,
                        primarySession: routingSession,
                        project: project
                    ),
                    primary.flatMap { sessionRank[$0.id] } ?? Int.max,
                    workspace.createdAt
                )
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.2 > $1.2
            }
            .filter { !$0.0.sessions.isEmpty || $0.0.primarySession != nil }
            .map(\.0)
    }

    private var expandedProjects: Set<UUID> {
        persistedIDs(from: expandedProjectsRaw)
    }

    private var expandedWorkspaces: Set<UUID> {
        persistedIDs(from: expandedWorkspacesRaw)
    }

    /// Sort tier for a chat row. Every state checked here is visible on the
    /// row as `SessionRow.statusIndicator` in the same precedence (error →
    /// attention → in progress → unread, matching the macOS sidebar); keep
    /// the two in sync. If sorting ever consults a state the icon doesn't
    /// show (the macOS sidebar once sorted a spinning chat by its hidden
    /// unread count), opening a chat reorders the list with no visible
    /// state change.
    private func priority(for session: ChatSession) -> Int {
        if session.hasUnreadError { return 0 }
        if session.actionRequired || session.pendingPlanApproval { return 1 }
        // Classification follows the icon precedence (a mid-run agent with
        // buffered unread turns shows the spinner, so it classifies as in
        // progress), while unread as a tier still ranks above in progress —
        // the same split the macOS sidebar makes.
        if ChatControllerCache.shared.isInProgress(session) { return 3 }
        if session.unreadCount > 0 { return 2 }
        return 4
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !hasRemoteMachines {
                    noMachineState
                } else if visibleSessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .onHover { isPointerInsideSidebar = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouchingSidebar) { _, isTouching, _ in
                        isTouching = true
                    }
            )
            .onChange(of: isPointerInsideSidebar || isTouchingSidebar) { _, isInteracting in
                setAutomaticOrderDeferred(isInteracting)
            }
            .onChange(of: visibleSessions.map(\.id)) { _, newIDs in
                deferredSessionOrder.incorporate(newIDs)
                backfillWorkspacesIfNeeded()
            }
            // Bursty automatic reorders (several agents changing state at
            // once) are jarring. Watching the unheld sort lets a burst land
            // as one animated reflow after it settles.
            .onChange(of: desiredVisibleSessions.map(\.id)) { _, _ in
                scheduleReorderSettleHold()
            }
            .onChange(of: organizationRaw, initial: true) { _, _ in
                backfillWorkspacesIfNeeded()
            }
            .onChange(of: presentedWorkspaceDisposition, initial: true) { _, disposition in
                applyPresentedWorkspaceDisposition(disposition)
            }
            .onDisappear {
                releaseDeferredOrder(animated: false)
            }
            .navigationTitle(organization.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // One glass group on the left: settings, then the machine
                // picker, mirroring the macOS toolbar's machine menu.
                ToolbarItemGroup(placement: .topBarLeading) {
                    machineMenu
                    settingsButton
                }
                ToolbarItem(placement: .topBarTrailing) { organizeMenu }
            }
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                if hasRemoteMachines {
                    newChatButton
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case let .workspace(workspaceId, anchorSessionId, preferredChatSessionId):
                    workspaceDestination(
                        workspaceId: workspaceId,
                        anchorSessionId: anchorSessionId,
                        preferredChatSessionId: preferredChatSessionId
                    )
                }
            }
            .refreshable {
                await machines.refreshSelectedNavigationState()
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsSheet()
            }
            .onReceive(NotificationCenter.default.publisher(for: .codevisorOpenSettings)) { _ in
                isShowingSettings = true
            }
            .sheet(isPresented: $isManagingMachines) {
                NavigationStack {
                    MachinesSettingsScreen()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isManagingMachines = false }
                            }
                        }
                }
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $newChatFlow, onDismiss: resetNewChatPresentation) { flow in
                newChatSheet(flow)
            }
            .fullScreenCover(isPresented: showsOnboarding) {
                onboardingStart = .welcome
            } content: {
                OnboardingView(start: onboardingStart)
                    // The QR flow lands here: alerts must present over the
                    // cover, so it carries its own copy of the deeplink
                    // alerts, active while it is the visible context.
                    .modifier(
                        MachineDeeplinkAlerts(
                            pending: $pendingDeeplink,
                            error: $deeplinkError,
                            isActive: true,
                            confirm: confirmDeeplink
                        )
                    )
            }
            // `codevisor://add-machine` deeplinks — the QR that `codevisor
            // setup`/`codevisor qr` prints, or the camera-scanned banner.
            // Never auto-add: the token grants full agent access, so an
            // explicit confirmation always sits between the link and the
            // machine list (same contract as macOS).
            .onOpenURL { url in
                // codevisor://cloud-auth deeplinks — the browser handoff back
                // from a cloud sign-in. The one-time token is proof by itself
                // (it expires within minutes and is single-use), so no
                // confirmation gate sits in front of the exchange.
                if let auth = CloudAuthDeeplink.parse(url) {
                    Task { await environment.cloud.completeSignIn(ott: auth.ott) }
                    return
                }
                guard let link = MachineDeeplink.parse(url) else { return }
                pendingDeeplink = link
            }
            .modifier(
                MachineDeeplinkAlerts(
                    pending: $pendingDeeplink,
                    error: $deeplinkError,
                    isActive: !showsOnboarding.wrappedValue,
                    confirm: confirmDeeplink
                )
            )
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                readyForOnboarding = true
            }
        }
    }

    /// Validated add from a confirmed deeplink: unreachable hosts and
    /// rejected tokens surface in the error alert instead of as a broken
    /// machine. Success selects the machine, which also closes onboarding.
    private func confirmDeeplink(_ link: MachineDeeplink) {
        pendingDeeplink = nil
        Task {
            do {
                let machine = try await environment.machines.addRemoteValidating(
                    host: link.hostWithPort,
                    name: link.name,
                    token: link.token
                )
                environment.machines.selectMachine(machine.id)
                await environment.prepareSelectedMachine()
            } catch {
                deeplinkError = ErrorReporter.userFacingMessage(for: error)
            }
        }
    }

    // MARK: - Lists

    private var sessionList: some View {
        List {
            switch organization {
            case .compact:
                Section {
                    ForEach(visibleSessions) { session in
                        chatRow(
                            session,
                            projectName: projectName(for: session),
                            showsFullWidthTopSeparator: session.id == visibleSessions.first?.id
                        )
                    }
                    .onMove { source, destination in
                        guard order == .none else { return }
                        moveSessions(from: source, to: destination)
                    }
                }
            case .byWorkspace:
                Section {
                    ForEach(workspaceItems) { item in
                        workspaceFolder(item, hierarchyDepth: 0)
                    }
                }
            case .byProject:
                ForEach(projectList.activeProjects.filter { !$0.isScratch }) { project in
                    let items = workspaceItems.filter { $0.workspace.projectId == project.id }
                    if !items.isEmpty {
                        Section {
                            projectFolder(project, items: items)
                        }
                    }
                }
                // Scratch-backed workspaces are not projects; match macOS by
                // keeping them at the root.
                let looseItems = workspaceItems.filter { $0.project?.isScratch != false }
                if !looseItems.isEmpty {
                    Section {
                        ForEach(looseItems) { item in
                            workspaceFolder(item, hierarchyDepth: 0)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .contentMargins(.bottom, 64, for: .scrollContent)
    }

    @ViewBuilder
    private func projectFolder(_ project: Project, items: [HomeWorkspaceListItem]) -> some View {
        Button {
            toggleProject(project.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: project.symbolName)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                Text(project.name)
                    .font(.body.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expandedProjects.contains(project.id) ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if expandedProjects.contains(project.id) {
            ForEach(items) { item in
                workspaceFolder(item, hierarchyDepth: 1)
            }
        }
    }

    /// The macOS hierarchy collapses a one-chat workspace directly to its
    /// agent row. Multi-chat workspaces expose the workspace itself plus its
    /// indented agents.
    @ViewBuilder
    private func workspaceFolder(
        _ item: HomeWorkspaceListItem,
        hierarchyDepth: Int
    ) -> some View {
        if item.sessions.count == 1, let session = item.sessions.first {
            chatRow(session, projectName: hierarchyDepth == 0 ? projectName(for: session) : nil)
                .padding(.leading, CGFloat(hierarchyDepth) * 18)
        } else {
            HStack(spacing: 0) {
                Button {
                    openWorkspace(item)
                } label: {
                    WorkspaceRow(
                        workspace: item.workspace,
                        projectName: hierarchyDepth == 0 ? item.project?.name : nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    toggleWorkspace(item.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 36, height: 36)
                        .rotationEffect(.degrees(expandedWorkspaces.contains(item.id) ? 90 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    expandedWorkspaces.contains(item.id)
                        ? "Collapse \(item.workspace.name)"
                        : "Expand \(item.workspace.name)"
                )
            }
            .padding(.leading, CGFloat(hierarchyDepth) * 18)
            .swipeActions(edge: .trailing) {
                Button {
                    environment.archiveWorkspace(item.workspace)
                    workspaceRevision += 1
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.orange)
            }

            if expandedWorkspaces.contains(item.id) {
                ForEach(item.sessions) { session in
                    chatRow(session, projectName: nil)
                        .padding(.leading, CGFloat(hierarchyDepth + 1) * 18)
                }
                if item.sessions.isEmpty {
                    Text("No tabs yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(hierarchyDepth + 1) * 18 + 48)
                }
            }
        }
    }

    private func chatRow(
        _ session: ChatSession,
        projectName: String?,
        showsFullWidthTopSeparator: Bool = false
    ) -> some View {
        Button {
            openChat(session)
        } label: {
            SessionRow(
                session: session,
                projectName: projectName,
                harnessSymbol: harnessSymbol(for: session)
            )
        }
        .buttonStyle(.plain)
        .modifier(FullWidthTopSeparatorModifier(isVisible: showsFullWidthTopSeparator))
        .swipeActions(edge: .trailing) {
            Button {
                _ = environment.archiveSessionAndWorkspaceIfEmpty(session)
                workspaceRevision += 1
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.orange)
        }
    }

    private func moveSessions(from source: IndexSet, to destination: Int) {
        var ids = visibleSessions.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        manualSessionOrder = ids.map(\.uuidString).joined(separator: "\n")
    }

    /// Entering a workspace restores its persisted selection, including a
    /// terminal. This is intentionally different from tapping one of its chat
    /// rows, which explicitly selects that chat before navigation.
    private func openWorkspace(_ item: HomeWorkspaceListItem) {
        guard let anchor = item.primarySession else { return }
        prepareController(for: anchor, workspaceId: item.id)
        path.append(
            .workspace(
                workspaceId: item.id,
                anchorSessionId: anchor.id,
                preferredChatSessionId: nil
            )
        )
    }

    /// Agent rows always open the agent itself, never the terminal or sibling
    /// chat that happened to be selected when the workspace was last left.
    private func openChat(_ session: ChatSession) {
        let workspace = ensureWorkspace(for: session)
        WorkspacePaneStore.shared.selectChat(
            session.id,
            in: workspace.id,
            legacySessionIds: [session.id] + workspace.chatSessionIds.filter { $0 != session.id }
        )
        prepareController(for: session, workspaceId: workspace.id)
        path.append(
            .workspace(
                workspaceId: workspace.id,
                anchorSessionId: session.id,
                preferredChatSessionId: session.id
            )
        )
    }

    private func prepareController(for session: ChatSession, workspaceId: UUID) {
        guard let project = projectList.projects.first(where: { $0.id == session.projectId }) else {
            return
        }
        _ = ChatControllerCache.shared.controller(
            for: session,
            project: project,
            workspaceId: workspaceId,
            environment: environment
        )
    }

    private func ensureWorkspace(for session: ChatSession) -> Workspace {
        let project = projectList.projects.first { $0.id == session.projectId }
        return environment.workspaces.ensureWorkspace(
            for: WorkspaceSessionSeed(
                sessionId: session.id,
                initialName: session.worktreeName ?? project?.name ?? "Workspace",
                serverId: session.serverId,
                projectId: session.projectId,
                rootDirectory: session.cwd ?? project?.folderURL.path,
                worktreeName: session.worktreeName
            ),
            legacyGroups: environment.paneGroups
        )
    }

    private func backfillWorkspacesIfNeeded() {
        guard organization != .compact else { return }

        let sessionsById = Dictionary(
            visibleSessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Before workspaces were represented in the iOS navigator, sibling
        // chats lived only in the original chat's local pane payload. Process
        // the broadest layouts first so their shared workspace claims every
        // child before ordinary one-chat backfill runs.
        let legacyLayouts = visibleSessions.compactMap { session -> (ChatSession, [UUID])? in
            guard let state = WorkspacePaneStore.shared.existingState(for: session.id) else {
                return nil
            }
            var seen: Set<UUID> = []
            let chatIds = state.panes.compactMap { pane -> UUID? in
                guard pane.kind == .chat,
                      let id = pane.chatSessionId,
                      sessionsById[id] != nil,
                      seen.insert(id).inserted
                else { return nil }
                return id
            }
            guard chatIds.count > 1, chatIds.contains(session.id) else { return nil }
            return (session, chatIds)
        }
        .sorted { $0.1.count > $1.1.count }

        for (anchor, chatIds) in legacyLayouts {
            var workspace = ensureWorkspace(for: anchor)
            var changed = false
            for chatId in chatIds where workspace.tabId(containingChat: chatId) == nil {
                workspace.centerTabs.append(
                    WorkspaceTab(root: .leaf(.centerInitial(sessionId: chatId)))
                )
                changed = true
            }
            if changed { environment.workspaces.save(workspace) }
        }

        for session in visibleSessions {
            _ = ensureWorkspace(for: session)
        }
        workspaceRevision += 1
    }

    private func persistedIDs(from rawValue: String) -> Set<UUID> {
        Set(rawValue.split(separator: "\n").compactMap { UUID(uuidString: String($0)) })
    }

    private func toggleProject(_ id: UUID) {
        var ids = expandedProjects
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        withAnimation(.snappy(duration: 0.28)) {
            expandedProjectsRaw = ids.map(\.uuidString).sorted().joined(separator: "\n")
        }
    }

    private func toggleWorkspace(_ id: UUID) {
        var ids = expandedWorkspaces
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        withAnimation(.snappy(duration: 0.28)) {
            expandedWorkspacesRaw = ids.map(\.uuidString).sorted().joined(separator: "\n")
        }
    }

    /// Shared Core policy decides whether the current route remains valid,
    /// moves to a surviving sibling chat, or leaves the workspace entirely.
    private var presentedWorkspaceDisposition: WorkspaceRouteDisposition {
        _ = environment.workspaceSync.revision
        guard case let .workspace(workspaceId, anchorSessionId, _)? = path.last else {
            return .keep
        }
        return environment.workspaceSync.routeDisposition(
            workspaceId: workspaceId,
            anchorSessionId: anchorSessionId,
            serverId: machines.selectedMachineId
        )
    }

    private func applyPresentedWorkspaceDisposition(_ disposition: WorkspaceRouteDisposition) {
        guard case let .workspace(workspaceId, anchorSessionId, _)? = path.last else { return }
        switch disposition {
        case .keep:
            break
        case let .selectSession(sessionId):
            guard sessionId != anchorSessionId else { return }
            path[path.count - 1] = .workspace(
                workspaceId: workspaceId,
                anchorSessionId: sessionId,
                preferredChatSessionId: sessionId
            )
        case .dismiss:
            // WorkspaceScreen may currently have a pane cover above it;
            // clearing the owning stack closes the whole workspace and
            // returns to the navigation list in one state transition.
            newChatFlow = nil
            path.removeAll()
        }
    }

    private func setAutomaticOrderDeferred(_ isDeferred: Bool) {
        if isDeferred {
            // The touch/hover hold takes over any in-flight settle hold (the
            // lock is first-snapshot-wins, so the frozen order is preserved)
            // and owns it until the interaction ends.
            cancelReorderSettleHold()
            deferredSessionOrder.lock(to: visibleSessions.map(\.id))
        } else {
            releaseDeferredOrder(animated: true)
        }
    }

    /// Coalesces bursts of automatic reorders. The first change of a burst
    /// commits immediately — it has already rendered by the time this runs —
    /// then the order freezes until the sort has been quiet for
    /// `ReorderSettle.quietDelay`, capped at `ReorderSettle.maxHold` under
    /// sustained churn. While the user is touching or hovering the list the
    /// interaction hold owns the lock instead, and its end releases
    /// immediately as before.
    private func scheduleReorderSettleHold() {
        guard order != .none, !isPointerInsideSidebar, !isTouchingSidebar else { return }
        if !deferredSessionOrder.isLocked {
            deferredSessionOrder.lock(to: visibleSessions.map(\.id))
            reorderSettleHoldStart = Date()
        }
        let holdStart = reorderSettleHoldStart ?? Date()
        reorderSettleTask?.cancel()
        reorderSettleTask = Task {
            try? await Task.sleep(for: .seconds(ReorderSettle.delay(holdStart: holdStart)))
            guard !Task.isCancelled else { return }
            reorderSettleTask = nil
            reorderSettleHoldStart = nil
            releaseDeferredOrder(animated: true)
        }
    }

    private func cancelReorderSettleHold() {
        reorderSettleTask?.cancel()
        reorderSettleTask = nil
        reorderSettleHoldStart = nil
    }

    private func releaseDeferredOrder(animated: Bool) {
        cancelReorderSettleHold()
        guard deferredSessionOrder.isLocked else { return }
        if animated {
            withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
                deferredSessionOrder.unlock()
            }
        } else {
            deferredSessionOrder.unlock()
        }
    }

    private func projectName(for session: ChatSession) -> String? {
        projectList.activeProjects.first { $0.id == session.projectId }?.name
    }

    /// Fallback SF symbol from the machine's cached capabilities, for
    /// harnesses without a bundled brand icon.
    private func harnessSymbol(for session: ChatSession) -> String {
        environment.configCache.capabilities(forServer: session.serverId)
            .first { $0.harness.id == session.harnessId }?
            .harness.symbolName ?? "cpu"
    }

    /// No machine paired (all machines removed): everything routes back
    /// into the onboarding connect page.
    private var noMachineState: some View {
        ContentUnavailableView {
            Label {
                Text("No Machine Connected")
            } icon: {
                Image("hunk")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.tertiary)
            }
        } description: {
            Text("Codevisor runs coding agents on your own Mac or Linux machine and streams them here.")
        } actions: {
            Button {
                onboardingStart = .connect
                onboardingDismissed = false
            } label: {
                Text("Connect a Machine")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }

    /// Mail-style empty state: the navigation title already supplies the
    /// context, so the body needs only a quiet confirmation that it is empty.
    private var emptyState: some View {
        VStack {
            Text("No \(organization.title)")
                .font(.title3.weight(.bold))
                .padding(.top, 80)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }

    /// The machine picker, as on macOS: paired machines with the selection
    /// checked, then Manage Machines at the bottom.
    private var machineMenu: some View {
        Menu {
            ForEach(machines.allMachines.filter { !$0.isLocal }) { machine in
                Button {
                    machines.selectMachine(machine.id)
                    Task { await environment.prepareSelectedMachine() }
                } label: {
                    if machine.id == machines.selectedMachineId {
                        Label(machine.name, systemImage: "checkmark")
                    } else {
                        Text(machine.name)
                    }
                }
            }
            Divider()
            Button {
                isManagingMachines = true
            } label: {
                Label("Manage Machines…", systemImage: "desktopcomputer")
            }
        } label: {
            Image(systemName: machines.selectedMachine.resolvedAppearance.symbolName)
        }
        .accessibilityLabel("Machine: \(machines.selectedMachine.name)")
    }

    /// The macOS sidebar's organize menu: Organization and Order pickers,
    /// plus reset when manually ordered.
    private var organizeMenu: some View {
        Menu {
            Picker("Organization", selection: $organizationRaw) {
                ForEach(HomeOrganization.allCases, id: \.rawValue) { organization in
                    Text(organization.title).tag(organization.rawValue)
                }
            }
            .pickerStyle(.menu)
            Picker("Order by", selection: $orderRaw) {
                ForEach(HomeOrder.allCases, id: \.rawValue) { order in
                    Text(order.title).tag(order.rawValue)
                }
            }
            .pickerStyle(.menu)
            if order == .none {
                Divider()
                Button("Reset manual order") { manualSessionOrder = "" }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Organize workspaces")
    }

    private var newChatButton: some View {
        Button {
            presentNewChat()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .matchedTransitionSource(
            id: Self.newChatTransitionID,
            in: newChatTransition
        )
        .padding(.trailing, 16)
        .padding(.bottom, 8)
        .accessibilityLabel("New chat")
    }

    private func presentNewChat() {
        newChatSheetPath = NavigationPath()
        newChatDetent = Self.newChatComposeDetent
        newChatFlow = NewChatFlow()
    }

    private func beginNewChatPromotion(_ sessionId: UUID, flow: NewChatFlow) {
        guard newChatFlow === flow, flow.sessionId == nil else { return }
        guard let session = projectList.sessions.first(where: { $0.id == sessionId }) else { return }
        flow.sessionId = sessionId
        let workspace = ensureWorkspace(for: session)

        // The real workspace is pushed underneath the opaque sheet. Its
        // normal route never receives the compose button's zoom transition,
        // so its eventual edge swipe is an ordinary navigation pop.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            path.append(
                .workspace(
                    workspaceId: workspace.id,
                    anchorSessionId: sessionId,
                    preferredChatSessionId: sessionId
                )
            )
        }

        guard newChatDetent != .large else {
            flow.isSheetExpanded = true
            finishNewChatPromotionIfReady(flow)
            return
        }
        withAnimation(.smooth, completionCriteria: .logicallyComplete) {
            newChatDetent = .large
        } completion: {
            guard newChatFlow === flow else { return }
            flow.isSheetExpanded = true
            finishNewChatPromotionIfReady(flow)
        }
    }

    private func markPromotedWorkspaceReady(_ sessionId: UUID) {
        guard let flow = newChatFlow, flow.sessionId == sessionId else { return }
        flow.isWorkspaceReady = true
        finishNewChatPromotionIfReady(flow)
    }

    /// Destination construction is deliberately read-only. Normal row taps
    /// populate the cache before pushing, while promoted drafts are registered
    /// there before this route appears.
    private func workspaceDestination(
        workspaceId: UUID,
        anchorSessionId: UUID,
        preferredChatSessionId: UUID?
    ) -> some View {
        let controller = projectList.sessions.first(where: { $0.id == anchorSessionId }).flatMap {
            ChatControllerCache.shared.existingController(
                sessionId: anchorSessionId,
                serverId: $0.serverId
            )
        }
        return WorkspaceScreen(
            sessionId: anchorSessionId,
            workspaceId: workspaceId,
            preferredChatSessionId: preferredChatSessionId,
            initialController: controller,
            onWorkspaceReady: markPromotedWorkspaceReady
        )
    }

    private func finishNewChatPromotionIfReady(_ flow: NewChatFlow) {
        guard newChatFlow === flow,
              flow.isSheetExpanded,
              flow.isWorkspaceReady
        else { return }

        // At `.large` the system sheet is opaque and the mounted destination
        // beneath it renders the same cached controller. Remove only the
        // presentation container; there is no second visible animation.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            newChatFlow = nil
        }
    }

    @ViewBuilder private func newChatSheet(_ flow: NewChatFlow) -> some View {
        NavigationStack(path: $newChatSheetPath) {
            WorkspaceScreen(
                sessionId: nil,
                isNewChatPresentation: true,
                initialComposerFocusRequest: flow.composerFocusRequest,
                onInitialComposerFocusRequestFulfilled: flow.consumeFocusRequest,
                onDraftStarted: { beginNewChatPromotion($0, flow: flow) },
                onInitialProjectAdded: returnToNewChatRoot
            )
        }
        .presentationDetents([.large], selection: $newChatDetent)
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(flow.sessionId != nil)
        .navigationTransition(
            .zoom(sourceID: Self.newChatTransitionID, in: newChatTransition)
        )
    }

    private func resetNewChatPresentation() {
        newChatSheetPath = NavigationPath()
        newChatDetent = Self.newChatComposeDetent
    }

    /// Folder rows add type-erased values to the sheet's own NavigationPath.
    /// Selecting one keeps the draft sheet alive and removes only those
    /// browser pushes.
    private func returnToNewChatRoot() {
        guard !newChatSheetPath.isEmpty else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            newChatSheetPath.removeLast(newChatSheetPath.count)
        }
    }
}

/// The first separator belongs to the list as a whole, rather than to the
/// first row's text column. Later separators retain the standard Mail-style
/// leading inset beneath the row copy.
private struct FullWidthTopSeparatorModifier: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        if isVisible {
            content
                .listRowSeparator(.hidden, edges: .top)
                .listRowBackground(
                    Color.clear.overlay(alignment: .top) {
                        Divider()
                            .padding(.horizontal, 16)
                    }
                )
        } else {
            content
        }
    }
}

/// Workspace rows are containers, matching the macOS sidebar hierarchy. A
/// tap opens the workspace's last-selected tab; the separate chevron expands
/// its chat children.
private struct WorkspaceRow: View {
    let workspace: Workspace
    let projectName: String?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: workspace.symbolName ?? "square.grid.2x2")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name.isEmpty ? "Workspace" : workspace.name)
                    .lineLimit(1)
                if let projectName {
                    Text(projectName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One chat row: status, harness icon, then the title over
/// "workspace · worktree". No timestamp — ordering already tells recency.
private struct SessionRow: View {
    private static let statusWidth: CGFloat = 10
    private static let statusToHarnessSpacing: CGFloat = 5
    private static let harnessWidth: CGFloat = 38
    private static let harnessToCopySpacing: CGFloat = 10
    private static let copyLeadingOffset = statusWidth
        + statusToHarnessSpacing
        + harnessWidth
        + harnessToCopySpacing

    let session: ChatSession
    let projectName: String?
    let harnessSymbol: String

    private var needsAttention: Bool { session.actionRequired || session.pendingPlanApproval }
    private var hasError: Bool { session.hasUnreadError }
    private var isUnread: Bool { session.unreadCount > 0 }
    private var isInProgress: Bool { ChatControllerCache.shared.isInProgress(session) }

    var body: some View {
        HStack(spacing: Self.harnessToCopySpacing) {
            HStack(spacing: Self.statusToHarnessSpacing) {
                statusIndicator
                harnessIcon
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? "New Chat" : session.title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let projectName {
                        Text(projectName)
                    }
                    if let worktree = session.worktreeName, !worktree.isEmpty {
                        if projectName != nil { Text("·") }
                        Text(worktree)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
        // SwiftUI otherwise infers a full-width bottom separator whenever a
        // visible status dot is the row's first child. Pin every row divider
        // to the copy column; only the custom title divider stays full width.
        .alignmentGuide(.listRowSeparatorLeading) { _ in
            Self.copyLeadingOffset
        }
    }

    /// Messages-style status gutter. Error → attention → in progress → unread
    /// is the same precedence as `ChatSessionLeadingIcon`, so a mid-run agent
    /// shows the working glyph even while it has buffered unread turns. The
    /// transparent idle state preserves avatar and copy alignment across rows.
    private var statusIndicator: some View {
        Group {
            if hasError {
                Circle().fill(.red).frame(width: 8, height: 8)
            } else if needsAttention {
                Circle().fill(.orange).frame(width: 8, height: 8)
            } else if isInProgress {
                AgentActivityIndicator()
            } else if isUnread {
                Circle().fill(.blue).frame(width: 8, height: 8)
            } else {
                Color.clear
            }
        }
        .frame(width: Self.statusWidth, height: Self.harnessWidth)
    }

    private var harnessIcon: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Color(.tertiarySystemFill))
            .frame(width: Self.harnessWidth, height: Self.harnessWidth)
            .overlay {
                HarnessIconView(
                    harnessId: session.harnessId,
                    fallbackSymbolName: harnessSymbol,
                    size: 20
                )
                .foregroundStyle(.secondary)
            }
    }
}

/// The macOS sidebar's Herdr-inspired working glyph, ported: ten braille
/// frames advancing at roughly eight steps per second in the status slot.
private struct AgentActivityIndicator: View {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.125, paused: reduceMotion)) { context in
            let frame = reduceMotion ? Self.frames[0] : Self.frame(at: context.date)
            Text(frame)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(.identity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }

    private static func frame(at date: Date) -> String {
        let tick = Int(date.timeIntervalSinceReferenceDate * 8)
        return frames[tick % frames.count]
    }
}

// MARK: - Machine deeplink alerts

/// The confirm + error alerts for `codevisor://add-machine` deeplinks,
/// mirroring the macOS handler. Applied twice — to the home content and to
/// the onboarding cover — with `isActive` selecting whichever is the visible
/// presentation context, so the same pending state presents in exactly one
/// place.
private struct MachineDeeplinkAlerts: ViewModifier {
    @Binding var pending: MachineDeeplink?
    @Binding var error: String?
    let isActive: Bool
    let confirm: (MachineDeeplink) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Add Remote Machine?",
                isPresented: Binding(
                    get: { isActive && pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                presenting: pending
            ) { deeplink in
                Button("Add \(deeplink.displayName)") { confirm(deeplink) }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { deeplink in
                Text(
                    """
                    “\(deeplink.displayName)” (\(deeplink.hostWithPort)) will be added to your \
                    machines. Codevisor will be able to run agents and read files on it.
                    """
                )
            }
            .alert(
                "Couldn't Add Machine",
                isPresented: Binding(
                    get: { isActive && error != nil },
                    set: { if !$0 { error = nil } }
                ),
                presenting: error
            ) { _ in
                Button("OK", role: .cancel) { error = nil }
            } message: { message in
                Text(message)
            }
    }
}

#Preview {
    HomeView()
        .environment(AppEnvironment.preview())
}
