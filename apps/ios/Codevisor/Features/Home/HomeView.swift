import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// The workspaces navigation screen: every workspace on the paired machine,
/// organized and ordered like the macOS sidebar, with settings at the top
/// left, the organize menu at the top right, and a fixed compose button at
/// the bottom trailing edge.
struct HomeView: View {
    private static let newChatTransitionID = "home-new-chat"

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ClientPreference("sidebar.organization", default: HomeOrganization.compact.rawValue)
    private var organizationRaw
    @ClientPreference("sidebar.order", default: HomeOrder.updated.rawValue)
    private var orderRaw
    @ClientPreference("sidebar.manualProjectOrder", default: "")
    private var manualProjectOrder
    @ClientPreference("sidebar.manualWorkspaceOrder", default: "")
    private var manualWorkspaceOrder
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
    @State private var newChatFlow: NewChatFlow?
    /// Presentation and promotion have different lifetimes. SwiftUI owns this
    /// item only while the native sheet exists; `newChatFlow` deliberately
    /// survives its removal until the overlay hands off to Home's real route.
    /// Using the item as the sheet input also guarantees the content closure
    /// is constructed with a non-nil flow on the very first presentation.
    @State private var presentedNewChatFlow: NewChatFlow?
    @State private var newChatSheetPath = NavigationPath()
    // A typed path lets Home identify the workspace currently presented and
    // pop it when a remote server refresh archives that chat.
    @State private var path: [HomeRoute] = []
    @State private var pendingDeeplink: MachineDeeplink?
    @State private var deeplinkError: String?
    /// A codevisor://install-plugin deeplink (the web plugin directory's
    /// "Open in Codevisor" button), staged until the install sheet presents.
    @State private var pendingPluginInstall: PendingPluginInstall?
    @State private var isPointerInsideSidebar = false
    @GestureState private var isTouchingSidebar = false
    /// Group reordering uses a dedicated flat List. The disclosure
    /// preferences remain untouched so returning restores the prior layout.
    @State private var groupReorderOrganization: HomeOrganization?
    @State private var groupReorderInitialOrder: String?
    @State private var deferredSessionOrder = InteractionDeferredOrder<UUID>()
    @State private var orderingCache = HomeSessionOrderingCache()
    /// Non-nil while a burst of automatic reorders is settling (the deferred
    /// order is locked without the user touching or hovering the list).
    @State private var reorderSettleHoldStart: Date?
    @State private var reorderSettleTask: Task<Void, Never>?
    /// The repository is deliberately non-observable. Bump this after a
    /// workspace backfill or local layout mutation so the hierarchy re-reads.
    @State private var workspaceRevision = 0
    @Namespace private var newChatTransition
    #if DEBUG || NAVIGATION_DIAGNOSTICS
        @State private var didHandleDiagnosticSessionLaunch = false
    #endif

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

    private var navigationSyncFailed: Bool {
        if case .stale = machines.selectedNavigationSyncState { return true }
        return false
    }

    /// Cached rows are intentionally hidden until lifecycle recovery has
    /// reconciled them. Ordinary live events and pull to refresh remain on the
    /// current presentation and therefore never enter this blocking state.
    private var needsNavigationLoadingState: Bool {
        switch machines.selectedNavigationSyncState {
        case .cached, .catchingUp:
            return true
        case .current, .stale:
            return false
        }
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
        // Flattened fleet: every machine's chats in one list.
        let sessions = projectList.sessions.filter { !$0.isArchived }
        let ordered = preferenceIDs(from: manualSessionOrder)
        let manualRanks = Dictionary(
            uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) }
        )
        return orderingCache.sessions(
            sessions,
            order: order,
            manualRanks: manualRanks,
            priority: priority
        )
    }

    /// Active chats on the selected machine, in the chosen order.
    private var visibleSessions: [ChatSession] {
        let desired = desiredVisibleSessions
        guard order != .none else { return desired }
        return deferredSessionOrder.applying(to: desired, id: \.id)
    }

    /// Workspace containers always follow their persisted manual order. Their
    /// children independently follow the selected agent ordering.
    private var workspaceItems: [HomeWorkspaceListItem] {
        _ = workspaceRevision
        _ = environment.workspaceSync.revision
        let sessionRank = Dictionary(
            visibleSessions.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: min
        )
        let sessionsById = Dictionary(
            visibleSessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let items = environment.workspaces.loadAll()
            .filter { !$0.isArchived }
            .map { workspace -> HomeWorkspaceListItem in
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
                .sorted {
                    (sessionRank[$0.id] ?? Int.max) < (sessionRank[$1.id] ?? Int.max)
                }
                let primary = sessions.first
                let routingSession =
                    primary
                    ?? visibleSessions.first {
                        environment.workspaces.workspaceId(forSession: $0.id) == workspace.id
                    }
                let project = projectList.projects.first {
                    $0.serverId == workspace.serverId && $0.id == workspace.projectId
                }
                return HomeWorkspaceListItem(
                    workspace: workspace,
                    sessions: sessions,
                    primarySession: routingSession,
                    project: project
                )
            }
            .filter { !$0.sessions.isEmpty || $0.primarySession != nil }
        return manuallyOrdered(
            items,
            ids: preferenceIDs(from: manualWorkspaceOrder),
            id: \.id
        )
    }

    private var projectItems: [HomeProjectListItem] {
        let items: [HomeProjectListItem] = projectList.fleetActiveProjects
            .filter { !$0.isScratch }
            .compactMap { project -> HomeProjectListItem? in
                let sessions = visibleSessions.filter { $0.projectId == project.id }
                guard !sessions.isEmpty else { return nil }
                return HomeProjectListItem(project: project, sessions: sessions)
            }
        return manuallyOrdered(
            items,
            ids: preferenceIDs(from: manualProjectOrder),
            id: \.id
        )
    }

    private var looseProjectSessions: [ChatSession] {
        let projectIDs = Set(
            projectList.fleetActiveProjects.lazy.filter { !$0.isScratch }.map(\.id)
        )
        return visibleSessions.filter { !projectIDs.contains($0.projectId) }
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
        status(for: session).rawValue
    }

    /// Classification follows the agent icon precedence. Raw status ordering
    /// separately lets unread outrank loading when aggregating different
    /// agents into one collapsed workspace indicator.
    private func status(for session: ChatSession) -> HomeSessionStatus {
        if session.hasUnreadError { return .error }
        if session.actionRequired || session.pendingPlanApproval { return .actionRequired }
        if ChatControllerCache.shared.isInProgress(session) { return .inProgress }
        if session.unreadCount > 0 { return .unread }
        return .idle
    }

    private func status(for item: HomeWorkspaceListItem) -> HomeSessionStatus {
        let sessions =
            item.sessions.isEmpty
            ? item.primarySession.map { [$0] } ?? []
            : item.sessions
        return sessions.map(status(for:)).min() ?? .idle
    }

    private func status(for item: HomeProjectListItem) -> HomeSessionStatus {
        item.sessions.map(status(for:)).min() ?? .idle
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !hasRemoteMachines {
                    noMachineState
                } else {
                    refreshableNavigationContent
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
            .onChange(of: path, initial: true) { oldPath, newPath in
                IOSNavigationDiagnostics.record(
                    "home.path",
                    "old=\(navigationPathSummary(oldPath)) new=\(navigationPathSummary(newPath))"
                )
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
                if groupReorderOrganization != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        groupReorderCancelButton
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        groupReorderConfirmButton
                    }
                } else {
                    // Settings on the left; Home itself is the fleet's, so
                    // there is no machine switcher — selection follows the
                    // chat you open, and machines are managed in Settings.
                    ToolbarItem(placement: .topBarLeading) { settingsButton }
                    ToolbarItem(placement: .topBarTrailing) { organizeMenu }
                }
            }
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                if hasRemoteMachines,
                    !navigationSyncFailed,
                    !needsNavigationLoadingState,
                    groupReorderOrganization == nil
                {
                    newChatButton
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case let .workspace(
                    serverId,
                    workspaceId,
                    anchorSessionId,
                    preferredChatSessionId
                ):
                    workspaceDestination(
                        serverId: serverId,
                        workspaceId: workspaceId,
                        anchorSessionId: anchorSessionId,
                        preferredChatSessionId: preferredChatSessionId
                    )
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsSheet()
            }
            .onReceive(NotificationCenter.default.publisher(for: .codevisorOpenSettings)) { _ in
                isShowingSettings = true
            }
            .sheet(item: $presentedNewChatFlow, onDismiss: handleNewChatSheetDismissed) {
                flow in
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
                            isActive: true
                        )
                    )
            }
            // External entries — codevisor:// deeplinks and notification
            // taps — parsed and routed in one modifier; chat opens (possibly
            // on another machine) come back through these closures.
            .modifier(
                HomeExternalRouting(
                    pendingDeeplink: $pendingDeeplink,
                    pendingPluginInstall: $pendingPluginInstall,
                    openSession: { openNotificationSession($0, serverId: $1) },
                    openDiagnosticSession: { id in
                        #if DEBUG || NAVIGATION_DIAGNOSTICS
                            openDiagnosticSession(id)
                        #endif
                    }
                )
            )
            .modifier(
                MachineDeeplinkAlerts(
                    pending: $pendingDeeplink,
                    error: $deeplinkError,
                    isActive: !showsOnboarding.wrappedValue
                )
            )
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                readyForOnboarding = true
                #if DEBUG || NAVIGATION_DIAGNOSTICS
                    if !didHandleDiagnosticSessionLaunch,
                        let value = ProcessInfo.processInfo.environment[
                            "CODEVISOR_DIAGNOSTIC_SESSION_ID"
                        ],
                        let id = UUID(uuidString: value)
                    {
                        didHandleDiagnosticSessionLaunch = true
                        for _ in 0..<50 {
                            if let session = projectList.sessions.first(where: {
                                $0.serverId == machines.selectedMachineId && $0.id == id
                            }) {
                                IOSNavigationDiagnostics.record(
                                    "home.diagnosticLaunchSession",
                                    "session=\(shortID(id))"
                                )
                                if let followupValue = ProcessInfo.processInfo.environment[
                                    "CODEVISOR_DIAGNOSTIC_FOLLOWUP_SESSION_ID"
                                ],
                                    let followupID = UUID(uuidString: followupValue)
                                {
                                    // Own this sequence independently of Home's
                                    // view task; pushing the first workspace
                                    // correctly cancels that view task.
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .seconds(4))
                                        path.removeAll()
                                        try? await Task.sleep(for: .milliseconds(750))
                                        if let followup = projectList.sessions.first(where: {
                                            $0.serverId == machines.selectedMachineId
                                                && $0.id == followupID
                                        }) {
                                            IOSNavigationDiagnostics.record(
                                                "home.diagnosticFollowupSession",
                                                "session=\(shortID(followupID))"
                                            )
                                            openChat(followup)
                                        }
                                    }
                                }
                                openChat(session)
                                break
                            }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                #endif
            }
        }
    }

    /// Validated add from a confirmed deeplink: unreachable hosts and
    /// rejected tokens surface in the error alert instead of as a broken
    /// machine. Success selects the machine, which also closes onboarding.
    // MARK: - Lists

    /// Keep pull to refresh available in every connected-machine state. A
    /// refresh action only installs a refresh control when it reaches a
    /// supported scroll container, so loading, empty, and unavailable states
    /// each need a real ScrollView rather than a static replacement view.
    @ViewBuilder
    private var refreshableNavigationContent: some View {
        if navigationSyncFailed {
            refreshableState {
                HomeNavigationSyncView(
                    state: .failed(machineName: machines.selectedMachine.name),
                    retry: {
                        Task { await machines.retrySelectedMachine() }
                    }
                )
            }
        } else if needsNavigationLoadingState {
            refreshableState {
                HomeNavigationSyncView(
                    state: .loading(machineName: machines.selectedMachine.name)
                )
            }
        } else if visibleSessions.isEmpty {
            refreshableState {
                emptyState
            }
        } else {
            sessionList
        }
    }

    /// A full-height native scroll surface preserves centered state content
    /// while allowing the standard iOS pull-to-refresh gesture even when
    /// there are no rows to make the content scroll naturally.
    private func refreshableState<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { proxy in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
            }
            .refreshable {
                await refreshNavigation()
            }
        }
    }

    private func refreshNavigation() async {
        await machines.refreshSelectedNavigationState()
    }

    @ViewBuilder
    private var sessionList: some View {
        if let groupReorderOrganization {
            groupReorderList(for: groupReorderOrganization)
        } else {
            navigationList
        }
    }

    private var navigationList: some View {
        List {
            switch organization {
            case .compact:
                Section {
                    ForEach(visibleSessions) { session in
                        chatRow(
                            session,
                            projectName: projectName(for: session),
                            hidesBottomSeparator: session.id == visibleSessions.last?.id
                        )
                    }
                    .onMove(perform: agentMoveAction(for: visibleSessions))
                }
                .listSectionSeparator(.visible, edges: .top)
            case .byWorkspace:
                Section {
                    ForEach(workspaceItems) { item in
                        workspaceDisclosure(
                            item,
                            isFinalRootItem: item.id == workspaceItems.last?.id
                        )
                    }
                }
            case .byProject:
                Section {
                    ForEach(projectItems) { item in
                        projectDisclosure(
                            item,
                            isFinalRootItem: looseProjectSessions.isEmpty
                                && item.id == projectItems.last?.id
                        )
                    }
                    // Scratch-backed and orphaned chats do not have a real
                    // project group; keep them as ordinary agent rows at root.
                    ForEach(looseProjectSessions) { session in
                        chatRow(
                            session,
                            projectName: projectName(for: session),
                            hidesBottomSeparator: session.id == looseProjectSessions.last?.id
                        )
                    }
                    .onMove(perform: agentMoveAction(for: looseProjectSessions))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .contentMargins(.bottom, 64, for: .scrollContent)
        .refreshable {
            await refreshNavigation()
        }
        .onChange(of: organizationRaw) { _, _ in
            clearGroupReorderPresentation()
        }
    }

    /// A deliberately flat edit-mode list keeps native move handles and
    /// animations independent from the disclosure hierarchy.
    @ViewBuilder
    private func groupReorderList(for organization: HomeOrganization) -> some View {
        List {
            Section {
                switch organization {
                case .byWorkspace:
                    ForEach(workspaceItems) { item in
                        WorkspaceDisclosureLabel(
                            workspace: item.workspace,
                            status: status(for: item),
                            showsStatus: true
                        )
                        .modifier(
                            BottomSeparatorModifier(
                                isHidden: item.id == workspaceItems.last?.id
                            )
                        )
                    }
                    .onMove(perform: moveWorkspaces)
                case .byProject:
                    ForEach(projectItems) { item in
                        ProjectDisclosureLabel(
                            project: item.project,
                            status: status(for: item),
                            showsStatus: true
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(
                            BottomSeparatorModifier(
                                isHidden: item.id == projectItems.last?.id
                            )
                        )
                    }
                    .onMove(perform: moveProjects)
                case .compact:
                    EmptyView()
                }
            }
            .listSectionSeparator(.visible, edges: .top)
        }
        .environment(\.editMode, .constant(.active))
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .contentMargins(.bottom, 24, for: .scrollContent)
        .refreshable {
            await refreshNavigation()
        }
    }

    /// Workspaces use the same native grouping pattern as projects. Collapsed
    /// labels summarize their most important child status; expanded labels
    /// leave status ownership to their direct agent children.
    private func workspaceDisclosure(
        _ item: HomeWorkspaceListItem,
        isFinalRootItem: Bool
    ) -> some View {
        let isReorderingGroups = groupReorderOrganization == .byWorkspace
        let isExpanded = !isReorderingGroups && expandedWorkspaces.contains(item.id)
        return DisclosureGroup(
            isExpanded: Binding(
                get: {
                    groupReorderOrganization != .byWorkspace
                        && expandedWorkspaces.contains(item.id)
                },
                set: { isExpanded in
                    guard groupReorderOrganization != .byWorkspace else { return }
                    setWorkspace(item.id, isExpanded: isExpanded)
                }
            )
        ) {
            ForEach(item.sessions) { session in
                chatRow(
                    session,
                    projectName: item.project?.name,
                    hidesBottomSeparator: isFinalRootItem
                        && session.id == item.sessions.last?.id
                )
            }
            .onMove(perform: agentMoveAction(for: item.sessions))
            if item.sessions.isEmpty {
                Text("No tabs yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .listRowSeparator(
                        isFinalRootItem ? .hidden : .visible,
                        edges: .bottom
                    )
            }
        } label: {
            WorkspaceDisclosureLabel(
                workspace: item.workspace,
                status: status(for: item),
                showsStatus: !isExpanded
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard groupReorderOrganization != .byWorkspace else { return }
                setWorkspace(item.id, isExpanded: !isExpanded)
            }
        }
        .tint(isReorderingGroups ? .clear : nil)
        .swipeActions(edge: .trailing) {
            Button {
                environment.archiveWorkspace(item.workspace)
                workspaceRevision += 1
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.orange)
        }
        .modifier(
            BottomSeparatorModifier(isHidden: isFinalRootItem && !isExpanded)
        )
    }

    private func projectDisclosure(
        _ item: HomeProjectListItem,
        isFinalRootItem: Bool
    ) -> some View {
        let isReorderingGroups = groupReorderOrganization == .byProject
        let isExpanded = !isReorderingGroups && expandedProjects.contains(item.id)
        return DisclosureGroup(
            isExpanded: Binding(
                get: {
                    groupReorderOrganization != .byProject
                        && expandedProjects.contains(item.id)
                },
                set: { isExpanded in
                    guard groupReorderOrganization != .byProject else { return }
                    setProject(item.id, isExpanded: isExpanded)
                }
            )
        ) {
            ForEach(item.sessions) { session in
                chatRow(
                    session,
                    projectName: nil,
                    hidesBottomSeparator: isFinalRootItem
                        && session.id == item.sessions.last?.id
                )
            }
            .onMove(perform: agentMoveAction(for: item.sessions))
        } label: {
            ProjectDisclosureLabel(
                project: item.project,
                status: status(for: item),
                showsStatus: !isExpanded
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .tint(isReorderingGroups ? .clear : nil)
        .modifier(
            BottomSeparatorModifier(isHidden: isFinalRootItem && !isExpanded)
        )
    }

    private func chatRow(
        _ session: ChatSession,
        projectName: String?,
        showsContext: Bool = true,
        hidesBottomSeparator: Bool? = nil
    ) -> some View {
        Button {
            openNotificationSession(session.id, serverId: session.serverId)
        } label: {
            SessionRow(
                session: session,
                projectName: projectName,
                harnessSymbol: harnessSymbol(for: session),
                status: status(for: session),
                showsContext: showsContext,
                machineName: machines.fleetMachineName(for: session.serverId)
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button {
                _ = environment.archiveSessionAndWorkspaceIfEmpty(session)
                workspaceRevision += 1
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.orange)
        }
        // Apply row traits outside the swipe wrapper so they reach the List's
        // actual cell rather than only the swipeable content hosted inside it.
        .modifier(BottomSeparatorModifier(isHidden: hidesBottomSeparator))
    }

    /// Group rows always use the same native List move interaction as agents.
    /// Persisting only these direct ForEach IDs keeps expanded disclosure
    /// children out of the destination model: a drop below an expanded group
    /// moves below that group rather than into its agent rows.
    private func moveWorkspaces(from source: IndexSet, to destination: Int) {
        var ids = workspaceItems.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        manualWorkspaceOrder = mergedPreferenceOrder(
            visibleIDs: ids,
            existingRawValue: manualWorkspaceOrder
        )
    }

    private func moveProjects(from source: IndexSet, to destination: Int) {
        var ids = projectItems.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        manualProjectOrder = mergedPreferenceOrder(
            visibleIDs: ids,
            existingRawValue: manualProjectOrder
        )
    }

    private func groupReorderBinding(for organization: HomeOrganization) -> Binding<Bool> {
        Binding(
            get: { groupReorderOrganization == organization },
            set: { isReordering in
                if isReordering {
                    beginGroupReorder(for: organization)
                } else {
                    finishGroupReorder()
                }
            }
        )
    }

    private func beginGroupReorder(for organization: HomeOrganization) {
        guard organization == self.organization,
            organization != .compact
        else { return }
        switch organization {
        case .byWorkspace:
            groupReorderInitialOrder = manualWorkspaceOrder
        case .byProject:
            groupReorderInitialOrder = manualProjectOrder
        case .compact:
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            groupReorderOrganization = organization
        }
    }

    private func cancelGroupReorder() {
        guard let organization = groupReorderOrganization,
            let initialOrder = groupReorderInitialOrder
        else {
            finishGroupReorder()
            return
        }
        withAnimation(.snappy(duration: 0.24)) {
            switch organization {
            case .byWorkspace:
                manualWorkspaceOrder = initialOrder
            case .byProject:
                manualProjectOrder = initialOrder
            case .compact:
                break
            }
            groupReorderOrganization = nil
        }
        groupReorderInitialOrder = nil
    }

    private func finishGroupReorder() {
        withAnimation(.snappy(duration: 0.24)) {
            groupReorderOrganization = nil
        }
        groupReorderInitialOrder = nil
    }

    private func clearGroupReorderPresentation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            groupReorderOrganization = nil
        }
        groupReorderInitialOrder = nil
    }

    private func agentMoveAction(
        for sessions: [ChatSession]
    ) -> ((IndexSet, Int) -> Void)? {
        guard order == .none, groupReorderOrganization == nil else { return nil }
        return { source, destination in
            moveSessions(sessions, from: source, to: destination)
        }
    }

    /// Reorders only the agents visible in a particular group, then projects
    /// that relative order back into the global manual agent sequence. This
    /// keeps agents in other projects/workspaces exactly where they were.
    private func moveSessions(
        _ sessions: [ChatSession],
        from source: IndexSet,
        to destination: Int
    ) {
        guard order == .none else { return }
        var movedIDs = sessions.map(\.id)
        movedIDs.move(fromOffsets: source, toOffset: destination)

        let movedIDSet = Set(movedIDs)
        var visibleIDs = visibleSessions.map(\.id)
        var replacements = movedIDs.makeIterator()
        for index in visibleIDs.indices where movedIDSet.contains(visibleIDs[index]) {
            guard let replacement = replacements.next() else { break }
            visibleIDs[index] = replacement
        }
        manualSessionOrder = mergedPreferenceOrder(
            visibleIDs: visibleIDs,
            existingRawValue: manualSessionOrder
        )
    }

    /// Agent rows always open the agent itself, never the terminal or sibling
    /// chat that happened to be selected when the workspace was last left.
    /// A notification tap lands here: switch to the chat's machine when
    /// needed, then open it — same contract as the macOS handler.
    private func openNotificationSession(_ sessionId: UUID, serverId: String) {
        Task {
            if machines.selectedMachineId != serverId {
                machines.selectMachine(serverId)
                await environment.prepareSelectedMachine()
            }
            guard
                let session = projectList.sessions.first(where: {
                    $0.serverId == serverId && $0.id == sessionId
                })
            else { return }
            openChat(session)
        }
    }

    #if DEBUG || NAVIGATION_DIAGNOSTICS
        private func openDiagnosticSession(_ id: UUID) {
            guard
                let session = projectList.sessions.first(where: {
                    $0.serverId == machines.selectedMachineId && $0.id == id
                })
            else { return }
            IOSNavigationDiagnostics.record(
                "home.diagnosticOpenSession",
                "session=\(shortID(id))"
            )
            openChat(session)
        }
    #endif

    private func openChat(_ session: ChatSession) {
        // Existing sessions take the O(1) index path. Only a legacy session
        // without a workspace pays the synchronous one-time backfill before
        // a routable destination id exists.
        let workspaceId =
            environment.workspaces.workspaceId(forSession: session.id)
            ?? ensureWorkspace(for: session).id
        IOSNavigationDiagnostics.record(
            "home.openChat",
            "workspace=\(shortID(workspaceId)) session=\(shortID(session.id)) pathBefore=\(navigationPathSummary(path))"
        )
        // Push first. Workspace pane selection, controller creation, history,
        // and transcript projection all begin from the destination's tasks.
        path.append(
            .workspace(
                serverId: session.serverId,
                workspaceId: workspaceId,
                anchorSessionId: session.id,
                preferredChatSessionId: session.id
            )
        )
    }

    private func ensureWorkspace(for session: ChatSession) -> Workspace {
        let project = projectList.projects.first {
            $0.serverId == session.serverId && $0.id == session.projectId
        }
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
        guard organization == .byWorkspace else { return }

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

    private func preferenceIDs(from rawValue: String) -> [UUID] {
        var seen: Set<UUID> = []
        return rawValue.split(separator: "\n").compactMap { rawID in
            guard let id = UUID(uuidString: String(rawID)), seen.insert(id).inserted else {
                return nil
            }
            return id
        }
    }

    private func persistedIDs(from rawValue: String) -> Set<UUID> {
        Set(preferenceIDs(from: rawValue))
    }

    /// Updates the selected machine's visible slice without discarding ranks
    /// saved for archived content or other paired machines.
    private func mergedPreferenceOrder(
        visibleIDs: [UUID],
        existingRawValue: String
    ) -> String {
        let visibleIDSet = Set(visibleIDs)
        let preservedIDs = preferenceIDs(from: existingRawValue).filter {
            !visibleIDSet.contains($0)
        }
        return (preservedIDs + visibleIDs).map(\.uuidString).joined(separator: "\n")
    }

    /// Applies a persistent manual rank while leaving newly-seen containers
    /// in their source order at the end until the user moves them.
    private func manuallyOrdered<Value>(
        _ values: [Value],
        ids: [UUID],
        id: KeyPath<Value, UUID>
    ) -> [Value] {
        let ranks = Dictionary(
            uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) }
        )
        return values.enumerated().sorted { left, right in
            let leftRank = ranks[left.element[keyPath: id]]
            let rightRank = ranks[right.element[keyPath: id]]
            switch (leftRank, rightRank) {
            case let (leftRank?, rightRank?): return leftRank < rightRank
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left.offset < right.offset
            }
        }.map(\.element)
    }

    private func setProject(_ id: UUID, isExpanded: Bool) {
        var ids = expandedProjects
        if isExpanded { ids.insert(id) } else { ids.remove(id) }
        withAnimation(.snappy(duration: 0.28)) {
            expandedProjectsRaw = ids.map(\.uuidString).sorted().joined(separator: "\n")
        }
    }

    private func setWorkspace(_ id: UUID, isExpanded: Bool) {
        var ids = expandedWorkspaces
        if isExpanded { ids.insert(id) } else { ids.remove(id) }
        withAnimation(.snappy(duration: 0.28)) {
            expandedWorkspacesRaw = ids.map(\.uuidString).sorted().joined(separator: "\n")
        }
    }

    /// Shared Core policy decides whether the current route remains valid,
    /// moves to a surviving sibling chat, or leaves the workspace entirely.
    private var presentedWorkspaceDisposition: WorkspaceRouteDisposition {
        _ = environment.workspaceSync.revision
        guard case let .workspace(serverId, workspaceId, anchorSessionId, _)? = path.last else {
            return .keep
        }
        return environment.workspaceSync.routeDisposition(
            workspaceId: workspaceId,
            anchorSessionId: anchorSessionId,
            serverId: serverId
        )
    }

    private func applyPresentedWorkspaceDisposition(_ disposition: WorkspaceRouteDisposition) {
        guard case let .workspace(serverId, workspaceId, anchorSessionId, _)? = path.last else {
            return
        }
        IOSNavigationDiagnostics.record(
            "home.routeDisposition",
            "value=\(routeDispositionSummary(disposition)) workspace=\(shortID(workspaceId)) anchor=\(shortID(anchorSessionId)) pathBefore=\(navigationPathSummary(path))"
        )
        switch disposition {
        case .keep:
            break
        case let .selectSession(sessionId):
            guard sessionId != anchorSessionId else { return }
            path[path.count - 1] = .workspace(
                serverId: serverId,
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

    private var groupReorderCancelButton: some View {
        Button("Cancel") {
            cancelGroupReorder()
        }
        .accessibilityLabel("Cancel reordering")
    }

    private var groupReorderConfirmButton: some View {
        Button(role: .confirm) {
            finishGroupReorder()
        } label: {
            Image(systemName: "checkmark")
        }
        .accessibilityLabel("Finish reordering")
    }

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }

    /// Organization controls grouping; ordering applies only to agent rows.
    private var organizeMenu: some View {
        Menu {
            Picker("Organization", selection: $organizationRaw) {
                ForEach(HomeOrganization.allCases, id: \.rawValue) { organization in
                    Text(organization.title).tag(organization.rawValue)
                }
            }
            .pickerStyle(.menu)
            Picker("Order agents by", selection: $orderRaw) {
                ForEach(HomeOrder.allCases, id: \.rawValue) { order in
                    Text(order.title).tag(order.rawValue)
                }
            }
            .pickerStyle(.menu)
            switch organization {
            case .compact:
                EmptyView()
            case .byWorkspace:
                Divider()
                Toggle(
                    "Reorder workspaces",
                    isOn: groupReorderBinding(for: .byWorkspace)
                )
            case .byProject:
                Divider()
                Toggle(
                    "Reorder projects",
                    isOn: groupReorderBinding(for: .byProject)
                )
            }
            if order == .none {
                Button("Reset agents order") { manualSessionOrder = "" }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Organize list")
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
        let flow = NewChatFlow()
        // Capture the navigation root before SwiftUI begins the native sheet
        // presentation. The promoted NavigationStack uses these exact pixels
        // as its root during an interactive back swipe.
        flow.homeSnapshot = currentHomeSnapshot()
        newChatFlow = flow
        presentedNewChatFlow = flow
    }

    private func beginNewChatPromotion(_ sessionId: UUID, flow: NewChatFlow) {
        guard newChatFlow === flow, flow.sessionId == nil else { return }
        guard
            // Fleet-wide: the draft may have been sent to ANOTHER machine's
            // project (session ids are unique across the fleet).
            let session = projectList.sessions.first(where: { $0.id == sessionId })
        else { return }
        // Deliberately NO machine switch here: the promotion animation is
        // mid-flight, and flipping the selected machine re-renders Home under
        // the snapshot and churns availability. iOS routes carry the
        // session's serverId end to end, so the selected machine simply
        // doesn't need to follow a send.
        flow.sessionId = sessionId
        let workspace = ensureWorkspace(for: session)
        // Host the surface in the PRESENTING (main) window, not the sheet's:
        // zoom presentations can put the sheet in a transient portal window
        // whose layer tree detaches from the render server — an animator
        // started there completes instantly, killing the whole morph.
        guard let presentationSession = flow.presentationSession,
            let presentationWindow = presentationSession.promotionHostWindow,
            let sourceFrame = presentationSession.visibleFrame(in: presentationWindow)
        else {
            // The resolver is installed with the first native-sheet frame, so
            // this should be unreachable in normal interaction. Keeping the
            // draft in the sheet is safer than starting a promotion without
            // exact source geometry.
            IOSNavigationDiagnostics.record(
                "home.newChatPromotion.skipped",
                "reason=sheet-geometry-missing session=\(shortID(sessionId))"
            )
            return
        }
        flow.promotionServerId = session.serverId
        flow.promotionWorkspaceId = workspace.id
        flow.promotionSourceFrame = sourceFrame
        flow.promotionSourceCornerRadius = presentationSession.presentationCornerRadius
        IOSNavigationDiagnostics.record(
            "home.newChatPromotion",
            "workspace=\(shortID(workspace.id)) session=\(shortID(sessionId)) pathBefore=\(navigationPathSummary(path))"
        )

        // Mount the real destination in Home's authoritative stack first. The
        // native sheet still covers this push, so it cannot flash or compete
        // with the system presentation. The morph reveals this exact route.
        path.append(
            .workspace(
                serverId: session.serverId,
                workspaceId: workspace.id,
                anchorSessionId: sessionId,
                preferredChatSessionId: sessionId
            )
        )

        // The replica starts at destination depth so its navigation chrome
        // matches the canonical route. It is destroyed when the morph ends.
        flow.promotionPath = [.workspace]

        // Install directly into the window we just measured. This cannot wait
        // on another SwiftUI appearance lifecycle: Home appeared long ago and
        // late zero-sized backgrounds are not promised a controller callback.
        // The retained pixel overlay covers the sheet before its draft state
        // can reconcile and reveal the already-mounted route underneath.
        let promotionSurface = NewChatPromotionSurface(
            window: presentationWindow,
            sourceFrame: sourceFrame,
            sourceCornerRadius: flow.promotionSourceCornerRadius,
            duration: reduceMotion ? 0 : TranscriptSendAnimationMetrics.duration,
            editorHandoffID: flow.id,
            sourceSnapshot: presentationSession.snapshotView(hidingComposerText: true),
            outgoingSourceEditorFrame: flow.outgoingSourceEditorFrame,
            liveContent: AnyView(
                newChatPromotionContent(flow)
                    .environment(environment)
            ),
            onInstalled: { [weak flow] in
                guard let flow else { return }
                promotionSurfaceInstalled(flow)
            },
            onExpanded: { [weak flow] in
                guard let flow, newChatFlow === flow else { return }
                flow.didFinishSurfaceAnimation = true
                finishNewChatPromotionIfReady(flow)
            }
        )
        flow.promotionSurface = promotionSurface
        flow.phase = .animating
        promotionSurface.install()
    }

    private func promotionSurfaceInstalled(_ flow: NewChatFlow) {
        guard newChatFlow === flow, flow.phase == .animating else { return }
        flow.didInstallPromotionSurface = true
        IOSNavigationDiagnostics.record("home.newChatPromotion.liveRouteMounted")
        expandPromotionSurfaceIfReady(flow)
    }

    private func markPromotedWorkspaceReady(_ sessionId: UUID) {
        guard let flow = newChatFlow, flow.sessionId == sessionId else { return }
        flow.isWorkspaceReady = true
        expandPromotionSurfaceIfReady(flow)
        finishNewChatPromotionIfReady(flow)
    }

    private func expandPromotionSurfaceIfReady(_ flow: NewChatFlow) {
        guard newChatFlow === flow,
            flow.didInstallPromotionSurface,
            flow.isWorkspaceReady
        else { return }
        flow.promotionSurface?.expand()
    }

    private func markFirstSendAnimationCompleted(
        _: UserSendAnimationRequest,
        flow: NewChatFlow
    ) {
        guard newChatFlow === flow else { return }
        flow.didFinishFirstSendAnimation = true
        finishNewChatPromotionIfReady(flow)
    }

    private func markFirstSendAnimationStarted(
        _: UserSendAnimationRequest,
        target: TranscriptSendAnimationTarget,
        sessionId: UUID
    ) -> Bool {
        guard let flow = newChatFlow,
            flow.sessionId == sessionId,
            flow.phase == .animating
        else { return false }
        return flow.promotionSurface?.setOutgoingMessageTarget(target) ?? false
    }

    /// Destination construction is deliberately read-only. Normal row taps
    /// populate the cache before pushing, while promoted drafts are registered
    /// there before this route appears.
    private func workspaceDestination(
        serverId: String,
        workspaceId: UUID,
        anchorSessionId: UUID,
        preferredChatSessionId: UUID?
    ) -> some View {
        let controller = projectList.sessions.first(where: {
            $0.serverId == serverId && $0.id == anchorSessionId
        }).flatMap { _ in
            ChatControllerCache.shared.existingController(
                sessionId: anchorSessionId,
                serverId: serverId
            )
        }
        let promotion = newChatFlow.flatMap { flow in
            flow.sessionId == anchorSessionId && flow.phase != .settled ? flow : nil
        }
        return WorkspaceScreen(
            sessionId: anchorSessionId,
            serverId: serverId,
            workspaceId: workspaceId,
            preferredChatSessionId: preferredChatSessionId,
            initialController: controller,
            onWorkspaceReady: markPromotedWorkspaceReady,
            // The canonical route lays out under the sheet but does not
            // consume shared transcript presentation state until commit.
            transcriptPresentationRole: promotion == nil ? .foreground : .prewarming,
            onSendAnimationStarted: { request, target in
                markFirstSendAnimationStarted(
                    request,
                    target: target,
                    sessionId: anchorSessionId
                )
            },
            composerTextEditorHandoffRole: promotion == nil
                ? .none
                : .promotionDestination,
            composerTextEditorHandoffID: promotion?.id
        )
    }

    private func finishNewChatPromotionIfReady(_ flow: NewChatFlow) {
        guard newChatFlow === flow,
            NewChatPromotionLifecycleContract.canCommit(
                phase: flow.phase,
                canonicalWorkspaceReady: flow.isWorkspaceReady,
                surfaceAnimationFinished: flow.didFinishSurfaceAnimation
            )
        else { return }

        // Home's canonical destination becomes the input owner before either
        // temporary surface is removed. It receives the exact first responder
        // from the sheet, preserving the keyboard through the structural swap.
        flow.phase = .committing
        _ = flow.promotionSurface?.completeStableEditorHandoff()
        flow.promotionSurface?.routeAccessibility(
            through: flow.presentationSession
        )
        commitNewChatPromotion(flow)
    }

    private func commitNewChatPromotion(_ flow: NewChatFlow) {
        let complete = {
            guard newChatFlow === flow else { return }

            // This terminal state removes every promotion-owned surface. The
            // already-mounted Home route switches to a normal foreground
            // workspace, and its composer adopts the exact portaled editor
            // back into the pane hierarchy during the same reconciliation.
            flow.phase = .settled
            let editorSettled = ComposerTextViewHandoffRegistry.settlePromotedEditor(
                id: flow.id
            )
            flow.promotionSurface?.remove()
            flow.promotionSurface = nil
            presentedNewChatFlow = nil
            newChatFlow = nil
            resetNewChatPresentation()
            IOSNavigationDiagnostics.record(
                "home.newChatPromotion.committed",
                "path=\(navigationPathSummary(path)) editorSettled=\(editorSettled)"
            )
        }

        // The opaque morph still owns visible pixels while UIKit removes the
        // genuine sheet. Its completion reveals Home's ready route and removes
        // the animation replica in one non-animated frame.
        if let presentationSession = flow.presentationSession {
            presentationSession.dismissWithoutAnimation(completion: complete)
        } else {
            complete()
        }
    }

    @ViewBuilder private func newChatPromotionContent(_ flow: NewChatFlow) -> some View {
        if let sessionId = flow.sessionId,
            let serverId = flow.promotionServerId,
            let workspaceId = flow.promotionWorkspaceId
        {
            let controller = ChatControllerCache.shared.existingController(
                sessionId: sessionId,
                serverId: serverId
            )
            NavigationStack(
                path: Binding(
                    get: { flow.promotionPath },
                    set: {
                        IOSNavigationDiagnostics.record(
                            "home.newChatPromotion.path",
                            "old=\(flow.promotionPath.count) new=\($0.count)"
                        )
                        flow.promotionPath = $0
                    }
                )
            ) {
                promotionHomeSnapshot(flow)
                    .navigationDestination(for: NewChatPromotionRoute.self) { route in
                        switch route {
                        case .workspace:
                            WorkspaceScreen(
                                sessionId: sessionId,
                                serverId: serverId,
                                workspaceId: workspaceId,
                                preferredChatSessionId: sessionId,
                                initialController: controller,
                                // Animation replica only: canonical readiness
                                // is reported by Home's real destination.
                                transcriptPresentationRole: .foreground,
                                onSendAnimationCompleted: {
                                    markFirstSendAnimationCompleted($0, flow: flow)
                                },
                                onSendAnimationStarted: { request, target in
                                    markFirstSendAnimationStarted(
                                        request,
                                        target: target,
                                        sessionId: sessionId
                                    )
                                },
                                extendsUnderPromotedHorizontalSafeArea: true,
                                // Never compete for the source responder. The
                                // canonical route is the handoff destination.
                                composerTextEditorHandoffRole: .none
                            )
                        }
                    }
            }
        } else {
            Color(.systemGroupedBackground)
        }
    }

    @ViewBuilder private func promotionHomeSnapshot(_ flow: NewChatFlow) -> some View {
        Group {
            if let snapshot = flow.homeSnapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .interpolation(.none)
            } else {
                Color(.systemGroupedBackground)
            }
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder private func newChatSheet(_ flow: NewChatFlow) -> some View {
        NewChatObservedContent(flow: flow) { liveFlow in
            AnyView(
                NavigationStack(path: $newChatSheetPath) {
                    WorkspaceScreen(
                        sessionId: nil,
                        isNewChatPresentation: true,
                        initialComposerFocusRequest: liveFlow.composerFocusRequest,
                        onInitialComposerFocusRequestFulfilled:
                            liveFlow.consumeFocusRequest,
                        onDraftStarted: {
                            beginNewChatPromotion($0, flow: liveFlow)
                        },
                        onDismissNewChat: { cancelNewChat(liveFlow) },
                        // Keep the presented hierarchy structurally inert
                        // through first send. Changing this role reconciled
                        // the source text view before the destination editor
                        // existed, which ended the keyboard session.
                        transcriptPresentationRole: .foreground,
                        onSendAnimationCompleted: {
                            markFirstSendAnimationCompleted($0, flow: liveFlow)
                        },
                        onComposerWillSend: { _, sourceFrame in
                            liveFlow.outgoingSourceEditorFrame = sourceFrame
                        },
                        composerTextEditorHandoffRole: .promotionSource,
                        composerTextEditorHandoffID: liveFlow.id
                    )
                }
                .background {
                    NewChatPresentationReader { session in
                        guard newChatFlow === liveFlow else { return }
                        liveFlow.presentationSession = session
                    }
                    .frame(width: 0, height: 0)
                }
            )
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .navigationTransition(
            .zoom(sourceID: Self.newChatTransitionID, in: newChatTransition)
        )
    }

    private func cancelNewChat(_ flow: NewChatFlow) {
        guard newChatFlow === flow, flow.sessionId == nil else { return }
        presentedNewChatFlow = nil
    }

    private func handleNewChatSheetDismissed() {
        guard let flow = newChatFlow else {
            resetNewChatPresentation()
            return
        }
        // Promotion keeps its state alive while the expanded live surface is
        // handed to the workspace route. A normal X/gesture dismissal clears
        // only presentation/editor ownership after the system transition;
        // the retained controller still owns the unsent draft value.
        guard flow.phase == .composing else {
            // UIKit is already inside SheetBridge's presentation preference
            // update here. Never force layout or first-responder traversal
            // from this callback; doing so is re-entrant and trips Swift's
            // exclusivity checker. Promotion state is finalized by the
            // dismissal completion and surface animation callbacks.
            return
        }
        ComposerTextViewHandoffRegistry.cancel(flow.id)
        newChatFlow = nil
        resetNewChatPresentation()
    }

    private func resetNewChatPresentation() {
        newChatSheetPath = NavigationPath()
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func navigationPathSummary(_ routes: [HomeRoute]) -> String {
        guard !routes.isEmpty else { return "[]" }
        return "["
            + routes.map { route in
                switch route {
                case let .workspace(
                    serverId,
                    workspaceId,
                    anchorSessionId,
                    preferredChatSessionId
                ):
                    let preferred = preferredChatSessionId.map(shortID) ?? "nil"
                    return "workspace(\(serverId)/\(shortID(workspaceId))/\(shortID(anchorSessionId))/\(preferred))"
                }
            }.joined(separator: ",") + "]"
    }

    private func routeDispositionSummary(_ disposition: WorkspaceRouteDisposition) -> String {
        switch disposition {
        case .keep:
            return "keep"
        case let .selectSession(sessionId):
            return "selectSession(\(shortID(sessionId)))"
        case .dismiss:
            return "dismiss"
        }
    }

    /// Folder rows add type-erased values to the sheet's own NavigationPath.
    /// Selecting one keeps the draft sheet alive and removes only those
    /// browser pushes.
}

/// Sheet-presentation wrapper for a parsed install-plugin deeplink: the repo
/// is the identity, so a second tap on the same link while the sheet is up
/// doesn't re-present it.
struct PendingPluginInstall: Identifiable {
    let repo: String
    var id: String { repo }
}

#Preview {
    HomeView()
        .environment(AppEnvironment.preview())
}
