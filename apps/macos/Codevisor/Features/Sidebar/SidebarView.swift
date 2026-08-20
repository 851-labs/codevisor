import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore
import CodevisorTheming
import os
import CodevisorUI

/// How many archived chats one page reveals.
private let archivedPageSize = 10

/// The sidebar: a New Chat action, an organization control, and the selected
/// machine's workspaces or agent sessions.
///
/// Built on `ScrollView` + `LazyVStack` (not `List`), because the sidebar-styled
/// `List` outline coordinator crashes on the current macOS SDK.
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: SidebarSelection?
    var store: SessionStore? = nil
    var publishesSceneActions = true

    @State private var addProjectFlow = AddProjectFlow()
    @State private var showingRemoteMachine = false
    @State private var pendingImport: PendingSessionImport?
    // Seeded from the SQLite preference after the view mounts; written back
    // using the established newline-separated UUID representation.
    @State private var expanded: Set<UUID> = []
    @State private var expandedWorkspaces: Set<UUID> = []
    @State private var iconEditing: Project?
    @State private var renamingSession: ChatSession?
    @State private var renameTitle = ""
    @State private var renamingWorkspace: Workspace?
    @State private var workspaceRenameTitle = ""
    @State private var workspaceIconEditing: Workspace?
    /// Bumped after workspace mutations (backfill sweep, renames) so the
    /// non-observable repository is re-read.
    @State private var workspaceRevision = 0
    @State private var draggingProjectID: UUID?
    @State private var draggingSessionID: UUID?
    @State private var isPointerInsideSidebar = false
    @State private var deferredProjectOrder = InteractionDeferredOrder<UUID>()
    @State private var deferredSessionOrder = InteractionDeferredOrder<UUID>()
    @State private var orderingCache = SidebarOrderingCache()
    /// Non-nil while a burst of automatic reorders is settling (the deferred
    /// orders are locked without the pointer being inside the sidebar).
    @State private var reorderSettleHoldStart: Date?
    @State private var reorderSettleTask: Task<Void, Never>?
    @ClientPreference("sidebar.organization", default: SidebarOrganization.compact.rawValue)
    private var organizationRaw
    @ClientPreference("sidebar.order", default: SidebarOrder.updated.rawValue)
    private var orderRaw
    @ClientPreference("sidebar.manualProjectOrder", default: "")
    private var manualProjectOrderRaw
    @ClientPreference("sidebar.manualSessionOrder", default: "")
    private var manualSessionOrderRaw
    @ClientPreference("sidebar.expandedProjects", default: "")
    private var expandedProjectsRaw
    @ClientPreference("sidebar.expandedWorkspaces", default: "")
    private var expandedWorkspacesRaw
    /// Archived content is hidden until explicitly enabled from the sidebar
    /// filter menu, and the choice survives relaunches.
    @ClientPreference("sidebar.showArchived", default: false) private var showArchived
    /// Collapsed by default: the archive is a place you go looking for
    /// something, not something that should crowd the live list.
    @ClientPreference("sidebar.archivedExpanded", default: false) private var archivedExpanded
    /// Page state is deliberately NOT persisted: reopening the archive should
    /// start at the newest page rather than restoring a deep scroll.
    @State private var archivedVisibleCount = archivedPageSize
    @State private var isLoadingMoreArchived = false
    /// The item a click is asking to restore, driving the confirmation alert.
    @State private var restoreRequest: ArchivedRestoreRequest?
    @ClientPreference("update.skippedVersion", default: "") private var skippedUpdateVersion
    @ClientPreference("update.skippedServerVersion", default: "") private var skippedServerUpdate

    private var list: ProjectListModel { environment.projectList }
    private var organization: SidebarOrganization { SidebarOrganization(rawValue: organizationRaw) ?? .compact }
    private var order: SidebarOrder { SidebarOrder(rawValue: orderRaw) ?? .updated }
    private var isReordering: Bool { draggingProjectID != nil || draggingSessionID != nil }
    private var itemTitleFont: Font { .body }
    private var hierarchyIndent: CGFloat { 8 }
    private var notificationColor: Color { theme.isSystem ? .blue : theme.accent }

    private var projectOrder: [UUID] {
        manualProjectOrderRaw
            .split(separator: "\n")
            .compactMap { UUID(uuidString: String($0)) }
    }

    private var sessionOrder: [UUID] {
        manualSessionOrderRaw
            .split(separator: "\n")
            .compactMap { UUID(uuidString: String($0)) }
    }

    private var visibleProjects: [Project] {
        let active = list.activeProjects
        if order == .none {
            return manuallyOrdered(active, ids: projectOrder, id: \.id)
        }
        return deferredProjectOrder.applying(to: automaticallySortedProjects, id: \.id)
    }

    private var automaticallySortedProjects: [Project] {
        orderingCache.projects(
            list.activeProjects,
            orderingKey: projectOrderingKey
        )
    }

    private var automaticallySortedSessions: [ChatSession] {
        let activeProjectIDs = Set(list.activeProjects.map(\.id))
        // The cache applies the final global order, so sourcing sessions via
        // `sessions(in:)` would first perform a throwaway per-project sort.
        // Filter the model's value array once instead.
        let sessions = list.sessions.filter { session in
            session.serverId == list.selectedServerId
                && activeProjectIDs.contains(session.projectId)
                && !session.isArchived
                && (session.origin == .codevisor || list.showsImportedSessions)
        }
        return orderingCache.sessions(
            sessions,
            priority: { order == .updated ? sessionPriority(for: $0) : .idle },
            timestamp: timestamp
        )
    }

    /// Projects shown as folders in "by project": scratch backing projects
    /// (the single-use folder behind a no-project chat) are not projects —
    /// their chats render at the list root instead.
    private var projectSectionProjects: [Project] {
        visibleProjects.filter { !$0.isScratch }
    }

    /// Match iOS by placing scratch-backed chats at the root and keeping
    /// workspace containers out of the "by project" organization.
    private var looseProjectSessions: [SidebarSessionListItem] {
        chronologicalSessions.filter(\.project.isScratch)
    }

    private var chronologicalSessions: [SidebarSessionListItem] {
        if order != .none {
            let projectsByID = Dictionary(
                visibleProjects.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let sorted = automaticallySortedSessions.compactMap { session -> SidebarSessionListItem? in
                guard let project = projectsByID[session.projectId] else { return nil }
                return SidebarSessionListItem(session: session, project: project)
            }
            return deferredSessionOrder.applying(to: sorted, id: \.id)
        }
        let sessions = visibleProjects.flatMap { project in
            list.sessions(in: project).map { SidebarSessionListItem(session: $0, project: project) }
        }
        return manuallyOrderedSessions(sessions, session: \.session)
    }

    /// The identity order the automatic sort wants right now, ignoring the
    /// hover and settle holds. Watched to coalesce bursts of reorders into a
    /// single reflow; empty under manual ordering, which never auto-reorders.
    private var desiredAutomaticOrderIDs: [UUID] {
        guard order != .none else { return [] }
        let projectIDs = automaticallySortedProjects.map(\.id)
        let sessionIDs = automaticallySortedSessions.map(\.id)
        return projectIDs + sessionIDs
    }

    /// "By workspace": every workspace on the selected machine, ordered like
    /// the chronological chat list (via each workspace's primary chat), with
    /// session-less workspaces last by creation date.
    private var workspaceItems: [SidebarWorkspaceListItem] {
        _ = workspaceRevision
        _ = environment.workspaceSync.revision
        let serverId = environment.machines.selectedMachineId
        let sessionItems = chronologicalSessions
        let sessionRank = Dictionary(
            sessionItems.enumerated().map { ($0.element.session.id, $0.offset) },
            uniquingKeysWith: min
        )
        let sessionsById = Dictionary(
            sessionItems.map { ($0.session.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let workspaces = environment.workspaces.loadAll().filter {
            $0.serverId == serverId && !$0.isArchived
        }
        return
            workspaces
            .map { workspace -> (item: SidebarWorkspaceListItem, rank: Int, created: Date) in
                let workspaceSessionItems = workspace.chatSessionIds.compactMap { id -> SidebarSessionListItem? in
                    guard environment.workspaces.workspaceId(forSession: id) == workspace.id else {
                        return nil
                    }
                    return sessionsById[id]
                }
                let workspaceSessions = workspaceSessionItems.map(\.session)
                let primary = workspaceSessionItems.first
                // A legacy or draft CHAT-LESS workspace stays openable
                // through any session still routed to it by the grow-only
                // session index — archived ones included.
                let routingSession =
                    primary?.session
                    ?? list.sessions.first(where: {
                        $0.serverId == serverId
                            && environment.workspaces.workspaceId(forSession: $0.id) == workspace.id
                    })
                let routingProject =
                    primary?.project
                    ?? routingSession.flatMap { fallback in
                        list.projects.first {
                            $0.serverId == serverId && $0.id == fallback.projectId
                        }
                    }
                return (
                    SidebarWorkspaceListItem(
                        workspace: workspace,
                        sessions: workspaceSessions,
                        primarySession: routingSession,
                        project: routingProject
                    ),
                    primary.flatMap { sessionRank[$0.session.id] } ?? Int.max,
                    workspace.createdAt
                )
            }
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.created > $1.created
            }
            .map(\.item)
    }

    /// Existing chats gain owning workspaces lazily; entering either
    /// workspace-based mode sweeps the visible sessions so the list is
    /// complete. Idempotent and cheap after the first pass (indexed lookups).
    private func backfillWorkspaces() {
        guard organization != .compact else { return }
        for item in chronologicalSessions {
            _ = environment.workspaces.ensureWorkspace(
                for: WorkspaceSessionSeed(
                    sessionId: item.session.id,
                    initialName: item.session.worktreeName ?? item.project.name,
                    serverId: item.session.serverId,
                    projectId: item.project.id,
                    rootDirectory: item.session.cwd ?? item.project.folderURL.path
                ),
                legacyGroups: environment.paneGroups
            )
        }
        workspaceRevision += 1
    }

    /// A newly created chat should be visible immediately in either
    /// workspace-based organization.
    /// Expand only for additions—not ordinary selection changes—so navigating
    /// among existing chats never overrides the user's disclosure choices.
    private func revealNewChatWorkspaces(_ sessionIDs: Set<UUID>) {
        guard organization != .compact, !sessionIDs.isEmpty else { return }

        let workspaces = sessionIDs.compactMap { sessionID -> Workspace? in
            guard let workspaceID = environment.workspaces.workspaceId(forSession: sessionID) else {
                return nil
            }
            return environment.workspaces.workspace(id: workspaceID)
        }
        guard !workspaces.isEmpty else { return }

        withAnimation(.snappy(duration: 0.28)) {
            if organization == .byProject {
                expanded.formUnion(workspaces.map(\.projectId))
            } else {
                expandedWorkspaces.formUnion(workspaces.map(\.id))
            }
        }
    }

    var body: some View {
        sidebarConfiguredView
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            SidebarUpdateBanners(
                environment: environment,
                store: store,
                skippedUpdateVersion: skippedUpdateVersion,
                skippedServerUpdate: skippedServerUpdate
            )
            // Development identity + New chat + the Projects header stay
            // pinned; only the project/chat list itself scrolls.
            VStack(alignment: .leading, spacing: 1) {
                if CodevisorAppVariant.isDevelopment {
                    SidebarDevelopmentWorktreeRow()
                }

                SidebarActionRow(
                    title: "New chat",
                    systemImage: "square.and.pencil",
                    isHoverEnabled: !isReordering
                ) {
                    selection = .newChat(nil)
                }

                projectsHeader
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            ScrollView {
                // A plain VStack: lazy row materialization re-measures the
                // content mid-bounce, which reads as random overscroll snaps.
                VStack(alignment: .leading, spacing: 1) {
                    // `.geometryGroup()` makes each row translate as one
                    // rigid unit during reflows. Without it a row whose
                    // content changes in the same transaction as its move
                    // (the state change that reorders a chat also restyles
                    // its leading icon) animates each subview's position
                    // independently, which reads as shearing/jitter.
                    if organization == .byProject {
                        ForEach(projectSectionProjects) { project in
                            projectFolder(project)
                                .geometryGroup()
                        }
                        // Chats without a real project (scratch-backed
                        // sessions) sit at the root as plain chat rows — a
                        // single-use folder is not a project.
                        ForEach(looseProjectSessions) { item in
                            reorderableChronologicalSessionRow(item.session, project: item.project)
                                .geometryGroup()
                                .transition(.identity)
                        }
                    } else if organization == .byWorkspace {
                        ForEach(workspaceItems) { item in
                            workspaceFolder(item)
                                .geometryGroup()
                                .transition(.identity)
                        }
                    } else {
                        ForEach(chronologicalSessions) { item in
                            reorderableChronologicalSessionRow(item.session, project: item.project)
                                .geometryGroup()
                                .transition(.identity)
                        }
                    }
                    if organization == .byProject && projectSectionProjects.isEmpty
                        && looseProjectSessions.isEmpty
                    {
                        Text("No projects yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    } else if organization == .byWorkspace && workspaceItems.isEmpty {
                        Text("No workspaces yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    } else if organization == .compact && chronologicalSessions.isEmpty {
                        Text("No agents yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }

                    if showArchived {
                        archivedSection
                    }

                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .animation(Motion.listReflow(reduceMotion: reduceMotion), value: workspaceItems.map(\.id))
                .animation(Motion.listReflow(reduceMotion: reduceMotion), value: chronologicalSessions.map(\.id))
                .animation(Motion.listReflow(reduceMotion: reduceMotion), value: visibleProjects.map(\.id))
                .animation(Motion.listReflow(reduceMotion: reduceMotion), value: expanded)
                .animation(Motion.listReflow(reduceMotion: reduceMotion), value: expandedWorkspaces)
                // Same reflow the project/workspace disclosures use, so the
                // archive opens and closes with the rest of the sidebar.
                .animation(Motion.listReflow(reduceMotion: reduceMotion), value: showArchived)
                .animation(Motion.listReflow(reduceMotion: reduceMotion), value: archivedExpanded)
                .animation(Motion.listReflow(reduceMotion: reduceMotion), value: archivedVisibleCount)
            }
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .contextMenu {
                sidebarFilterMenuContent
            }

        }
    }

    private var sidebarInteractionView: some View {
        sidebarContent
            .themedSurface(.sidebar)
            .hoverTracking($isPointerInsideSidebar, respectsSuspension: false)
            .onChange(of: isPointerInsideSidebar) { _, isInside in
                setAutomaticOrderDeferred(isInside)
            }
            .onDisappear {
                releaseDeferredOrder(animated: false)
            }
            .addProjectFlow(addProjectFlow) { project in
                expanded.insert(project.id)
                selection = .newChat(project.id)
                offerSessionImport(for: project)
            }
    }

    private var sidebarAlertsView: some View {
        sidebarInteractionView
            .modifier(
                SidebarAlertsModifier(
                    pendingImport: $pendingImport,
                    renamingSession: $renamingSession,
                    renameTitle: $renameTitle,
                    renamingWorkspace: $renamingWorkspace,
                    workspaceRenameTitle: $workspaceRenameTitle,
                    restoreRequest: $restoreRequest,
                    onImport: { environment.importSessions($0.sessions, into: $0.project) },
                    onRenameSession: { list.renameSession($0, to: $1) },
                    onRenameWorkspace: { renamed in
                        environment.workspaces.save(renamed)
                        workspaceRevision += 1
                    },
                    onPerformRestore: { performRestore($0) }
                ))
    }

    private var sidebarChangeObserversView: some View {
        sidebarAlertsView
            // Collapsing resets paging so reopening starts at the newest page
            // instead of restoring a deep scroll the user has forgotten about.
            .onChange(of: archivedExpanded) { _, isExpanded in
                if !isExpanded {
                    archivedVisibleCount = archivedPageSize
                    isLoadingMoreArchived = false
                }
            }
            // Entering a workspace-based mode (or sessions changing while in it)
            // sweeps the visible chats so every one has an owning workspace.
            .onChange(of: organizationRaw, initial: true) { _, _ in
                backfillWorkspaces()
            }
            .onChange(of: chronologicalSessions.map(\.id)) { oldIDs, newIDs in
                deferredSessionOrder.incorporate(newIDs)
                backfillWorkspaces()
                revealNewChatWorkspaces(Set(newIDs).subtracting(Set(oldIDs)))
            }
            .onChange(of: visibleProjects.map(\.id)) { _, newIDs in
                deferredProjectOrder.incorporate(newIDs)
            }
            // Bursty automatic reorders (several agents changing state at once)
            // are jarring, and each interrupts the previous reflow animation
            // mid-flight, which reads as jitter. Watching the unheld sort lets a
            // burst land as one clean reflow after it settles.
            .onChange(of: desiredAutomaticOrderIDs) { _, _ in
                scheduleReorderSettleHold()
            }
    }

    private var sidebarSheetsView: some View {
        sidebarChangeObserversView
            .modifier(
                SidebarSheetsModifier(
                    iconEditing: $iconEditing,
                    workspaceIconEditing: $workspaceIconEditing,
                    showingRemoteMachine: $showingRemoteMachine,
                    list: list,
                    onSaveWorkspace: { updated in
                        environment.workspaces.save(updated)
                        workspaceRevision += 1
                    },
                    onAddRemoteMachine: { host, name, token in
                        do {
                            try await environment.machines.addRemoteValidating(host: host, name: name, token: token)
                            selection = .newChat(nil)
                            return nil
                        } catch {
                            Log.machines.error(
                                "Adding remote machine failed: \(String(describing: error), privacy: .public)")
                            if case CodevisorServerClientError.httpStatus(401, _) = error {
                                return "That connection token was rejected by the machine."
                            }
                            return serverErrorMessage(error)
                        }
                    }
                ))
    }

    private var sidebarConfiguredView: some View {
        sidebarSheetsView
            .onAppear(perform: restoreExpandedState)
            .onChange(of: expanded) { _, newValue in
                expandedProjectsRaw = newValue.map(\.uuidString).sorted().joined(separator: "\n")
            }
            .onChange(of: expandedWorkspaces) { _, newValue in
                expandedWorkspacesRaw = newValue.map(\.uuidString).sorted().joined(separator: "\n")
            }
            .focusedSceneValue(
                \.sidebarActions,
                publishesSceneActions
                    ? SidebarActions(
                        newChat: { selection = .newChat(nil) },
                        newProject: { startAddProject() },
                        addRemoteMachine: { showingRemoteMachine = true }
                    )
                    : nil
            )
    }

    /// One shared flow: pick a folder on the machine or clone a repository.
    private func startAddProject() {
        addProjectFlow.begin()
    }

    private func restoreExpandedState() {
        expanded = persistedIDs(from: expandedProjectsRaw)
        expandedWorkspaces = persistedIDs(from: expandedWorkspacesRaw)
    }

    private func persistedIDs(from rawValue: String) -> Set<UUID> {
        let ids: [UUID] =
            rawValue
            .split(separator: "\n")
            .compactMap { UUID(uuidString: String($0)) }
        return Set(ids)
    }

    /// After a project is added, look for existing harness sessions in its
    /// folder and — only when some are found — offer to import them.
    private func offerSessionImport(for project: Project) {
        Task {
            let importable = await environment.findImportableSessions(for: project.folderURL)
            guard !importable.isEmpty else { return }
            pendingImport = PendingSessionImport(project: project, sessions: importable)
        }
    }

    // MARK: - Header rows

    private var projectsHeader: some View {
        HStack {
            Text(
                {
                    switch organization {
                    case .byWorkspace: "Workspaces"
                    case .compact: "Agents"
                    case .byProject: "Projects"
                    }
                }()
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            Spacer()
            Menu {
                sidebarFilterMenuContent
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .help("Organize and filter sidebar")
            .accessibilityLabel("Organize and filter sidebar")
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// Shared by the filter button and the empty-space sidebar context menu so
    /// both entry points always expose the same organization and filter state.
    private var sidebarFilterMenuContent: some View {
        SidebarFilterMenu(
            organization: organization,
            order: order,
            showArchived: $showArchived,
            onSetOrganization: { organizationRaw = $0.rawValue },
            onSetOrder: { setOrder($0) },
            onResetManualOrder: { resetManualOrder() }
        )
    }

    // MARK: - Project rows

    @ViewBuilder
    private func projectFolder(_ project: Project) -> some View {
        reorderableProjectRow(project)

        // Keep the persisted disclosure state intact while making the list
        // compact enough to reorder. Ending the drag restores every folder
        // exactly as the user left it.
        if isProjectVisuallyExpanded(project.id) {
            let sessions = orderedSessions(in: project)
            ForEach(sessions) { session in
                reorderableChronologicalSessionRow(session, project: project, isNested: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            if sessions.isEmpty {
                Text("No chats yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 16)
                    .padding(.vertical, 3)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func workspaceFolder(_ item: SidebarWorkspaceListItem) -> some View {
        let isExpanded = expandedWorkspaces.contains(item.id)
        workspaceRow(
            item,
            isExpanded: isExpanded,
            onToggle: { toggleWorkspace(item.id) }
        )

        if expandedWorkspaces.contains(item.id) {
            if let project = item.project {
                ForEach(item.sessions) { session in
                    reorderableChronologicalSessionRow(session, project: project, isNested: true)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
            if item.sessions.isEmpty {
                Text("No tabs yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(
                        .leading,
                        8 + hierarchyIndent + 24
                    )
                    .padding(.vertical, 3)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func reorderableProjectRow(_ project: Project) -> some View {
        if order == .none {
            projectRow(project)
                .onDrag(
                    {
                        draggingProjectID = project.id
                        return NSItemProvider(object: project.id.uuidString as NSString)
                    },
                    preview: {
                        projectRow(project, isDragPreview: true)
                            .frame(width: 260)
                    }
                )
                .opacity(draggingProjectID == project.id ? 0 : 1)
                .onDrop(
                    of: [.text],
                    delegate: ProjectDropDelegate(
                        projectID: project.id,
                        draggingProjectID: $draggingProjectID,
                        moveProject: moveProject
                    )
                )
        } else {
            projectRow(project)
        }
    }

    private func projectRow(
        _ project: Project,
        isDragPreview: Bool = false,
        isArchivedEntry: Bool = false
    ) -> some View {
        SidebarProjectRow(
            project: project,
            isDragPreview: isDragPreview,
            isArchivedEntry: isArchivedEntry,
            isReordering: isReordering,
            isVisuallyExpanded: isProjectVisuallyExpanded(project.id),
            titleFont: itemTitleFont,
            onDisclosureToggle: { toggle(project.id) },
            onRestoreRequest: { restoreRequest = ArchivedRestoreRequest(target: .project(project)) },
            onNewChat: { selection = .newChat(project.id) },
            onChangeIcon: { iconEditing = project },
            onArchive: { list.archive(project) }
        )
    }

    private func disclosureRow(
        id: String,
        title: String,
        systemImage: String?,
        isOpen: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
            if let systemImage {
                Image(systemName: systemImage).frame(width: 18).foregroundStyle(.secondary)
            }
            Text(title).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .sidebarRowHover(isEnabled: !isReordering)
        .onTapGesture(perform: toggle)
    }

    /// Archived projects and chats, kept in one collapsed disclosure at the
    /// bottom of the sidebar rather than a separate screen — restoring stays a
    /// two-click operation in the place the user already is.
    ///
    /// Archived chats of an ARCHIVED project are intentionally omitted: they
    /// appear nested under that project once it is restored. Listing them at
    /// this level too would show the same chat twice.
    @ViewBuilder
    private var archivedSection: some View {
        let projects = list.archivedProjects
        // Chats archived inside an ARCHIVED project are omitted: they come
        // back with that project, and listing them here as well would show
        // the same chat in two places.
        let archivedProjectIDs = Set(projects.map(\.id))
        let chats = list.archivedSessions.compactMap { session -> SidebarSessionListItem? in
            guard !archivedProjectIDs.contains(session.projectId),
                let project = list.projects.first(where: {
                    $0.serverId == session.serverId && $0.id == session.projectId
                })
            else { return nil }
            return SidebarSessionListItem(session: session, project: project)
        }
        if !projects.isEmpty || !chats.isEmpty {
            archivedHeader
            if archivedExpanded {
                ForEach(projects) { project in
                    archivedProjectRow(project)
                        .transition(Motion.unfold(reduceMotion: reduceMotion))
                }
                // Paged: a long archive would otherwise make every sidebar
                // reflow lay out hundreds of rows it never shows.
                ForEach(chats.prefix(archivedVisibleCount)) { item in
                    archivedSessionRow(item.session, project: item.project)
                        .transition(Motion.unfold(reduceMotion: reduceMotion))
                }
                if chats.count > archivedVisibleCount {
                    showMoreArchivedRow(remaining: chats.count - archivedVisibleCount)
                        .transition(Motion.unfold(reduceMotion: reduceMotion))
                }
            }
        }
    }

    private func showMoreArchivedRow(remaining: Int) -> some View {
        SidebarShowMoreArchivedRow(
            remaining: remaining,
            pageSize: archivedPageSize,
            titleFont: itemTitleFont,
            archivedVisibleCount: $archivedVisibleCount,
            isLoadingMoreArchived: $isLoadingMoreArchived
        )
    }

    private var archivedHeader: some View {
        SidebarArchivedHeader(archivedExpanded: $archivedExpanded)
    }

    /// Archived rows deliberately reuse the live row builders rather than
    /// defining their own look: an archived chat should be visually identical
    /// to an active one in whichever organization is selected, so the archive
    /// reads as the same list rather than a separate widget. `isArchivedEntry`
    /// only swaps the row's behavior (click asks to restore, and the archive
    /// affordances are dropped), never its styling.
    private func archivedProjectRow(_ project: Project) -> some View {
        projectRow(project, isArchivedEntry: true)
    }

    @ViewBuilder
    private func archivedSessionRow(_ session: ChatSession, project: Project) -> some View {
        // Every organization deliberately shares the exact same agent row;
        // only the live hierarchy around it changes.
        chronologicalSessionRow(session, project: project, isArchivedEntry: true)
    }

    /// Restores a chat and revives its workspace, mirroring the archive
    /// policy in reverse (`archiveSessionAndWorkspaceIfEmpty`).
    private func restoreChat(_ session: ChatSession) {
        list.unarchiveSession(session)
        if let workspaceId = environment.workspaces.workspaceId(forSession: session.id),
            let workspace = environment.workspaces.workspace(id: workspaceId),
            workspace.isArchived
        {
            environment.unarchiveWorkspace(workspace)
        }
        workspaceRevision += 1
    }

    /// Applies a confirmed restore and opens the chat, which is what the user
    /// was reaching into the archive for.
    private func performRestore(_ request: ArchivedRestoreRequest) {
        switch request.target {
        case let .project(project):
            list.unarchive(project)
        case let .session(session):
            restoreChat(session)
            activateSession(session)
        }
    }

    private func sessionRow(
        _ session: ChatSession,
        isDragPreview: Bool = false,
        hierarchyDepth: Int = 0,
        isArchivedEntry: Bool = false,
        activatesOnMouseDown: Bool = true
    ) -> some View {
        let isSelected =
            !isDragPreview
            && !isArchivedEntry
            && selection == .session(serverId: session.serverId, id: session.id)
        return SidebarSessionRow(
            session: session,
            store: store,
            isDragPreview: isDragPreview,
            hierarchyDepth: hierarchyDepth,
            isArchivedEntry: isArchivedEntry,
            activatesOnMouseDown: activatesOnMouseDown,
            isSelected: isSelected,
            isReordering: isReordering,
            titleFont: itemTitleFont,
            hierarchyIndent: hierarchyIndent,
            isUnread: { isUnread(session) },
            onActivate: { activateSession(session) },
            onRestoreRequest: { restoreRequest = ArchivedRestoreRequest(target: .session(session)) },
            onRename: {
                renameTitle = session.title
                renamingSession = session
            },
            onArchive: { archiveChat(session) },
            onMarkRead: { store?.markRead(session) },
            onMarkUnread: {
                store?.markUnread(session)
                if selection == .session(serverId: session.serverId, id: session.id) {
                    selectNextChat(excluding: [session.id], serverId: session.serverId)
                }
            }
        )
    }

    /// One workspace row, either top-level or nested beneath its project.
    /// Nested rows are disclosure-only; top-level workspace rows retain their
    /// primary-chat activation behavior.
    private func workspaceRow(
        _ item: SidebarWorkspaceListItem,
        isExpanded: Bool = false,
        onToggle: (() -> Void)? = nil
    ) -> some View {
        // Top-level workspace organization uses workspace selection styling.
        // A nested workspace is only a disclosure container; its child chat
        // owns selection instead.
        let routesSelectedSession: Bool = {
            guard case let .session(serverId, sessionId) = selection,
                serverId == item.workspace.serverId
            else { return false }
            return environment.workspaces.workspaceId(forSession: sessionId) == item.workspace.id
        }()
        let isSelected = onToggle == nil && routesSelectedSession
        return SidebarWorkspaceRow(
            item: item,
            store: store,
            isExpanded: isExpanded,
            onToggle: onToggle,
            isSelected: isSelected,
            isReordering: isReordering,
            titleFont: itemTitleFont,
            onActivateSession: { activateSession($0) },
            onArchive: { archiveWorkspace(item) },
            onRename: {
                workspaceRenameTitle = item.workspace.name
                renamingWorkspace = item.workspace
            },
            onChangeIcon: { workspaceIconEditing = item.workspace }
        )
    }

    /// Archives the WORKSPACE (not just a chat): the record is flagged, its
    /// live chats archive with it, and the row leaves the list. Layout is
    /// kept — restoring any of its chats revives the whole workspace.
    private func archiveWorkspace(_ item: SidebarWorkspaceListItem) {
        archiveWorkspace(item.workspace)
    }

    private func archiveWorkspace(_ workspace: Workspace) {
        // Whether the selection lives in this workspace, decided BEFORE the
        // archive (a scratch workspace's discard also drops its session
        // index, which this lookup depends on).
        let selectionLeaves: Bool
        if case let .session(serverId, sessionId) = selection,
            serverId == workspace.serverId,
            environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
        {
            selectionLeaves = true
        } else {
            selectionLeaves = false
        }
        environment.archiveWorkspace(workspace)
        if selectionLeaves {
            // Land on the most recent remaining chat; only an empty machine
            // falls through to creating a fresh scratch workspace.
            selectNextChat(excluding: [], serverId: workspace.serverId)
        }
        workspaceRevision += 1
    }

    /// Moves the selection off a chat that is leaving the screen (archive,
    /// mark-as-unread) to the most recent OTHER active chat. Only when none
    /// remain does the empty fallback create a fresh scratch workspace.
    private func selectNextChat(excluding excluded: Set<UUID>, serverId: String) {
        let next = environment.projectList.sessions
            .filter { $0.serverId == serverId && !$0.isArchived && !excluded.contains($0.id) }
            .max { ($0.updatedAt ?? $0.createdAt) < ($1.updatedAt ?? $1.createdAt) }
        selection = next.map { .session(serverId: $0.serverId, id: $0.id) }
    }

    private func chronologicalSessionRow(
        _ session: ChatSession,
        project: Project,
        isDragPreview: Bool = false,
        isArchivedEntry: Bool = false,
        isNested: Bool = false
    ) -> some View {
        let isSelected =
            !isDragPreview
            && !isArchivedEntry
            && selection == .session(serverId: session.serverId, id: session.id)
        // Manual-order chat rows attach this gesture alongside their native
        // drag source so activation does not prevent drag-to-reorder.
        return SidebarChronologicalSessionRow(
            session: session,
            project: project,
            store: store,
            isDragPreview: isDragPreview,
            isArchivedEntry: isArchivedEntry,
            hierarchyDepth: isNested ? 1 : 0,
            hierarchyIndent: hierarchyIndent,
            showsProjectName: !isNested || organization != .byProject,
            isSelected: isSelected,
            activatesOnMouseDown: order != .none,
            isReordering: isReordering,
            titleFont: itemTitleFont,
            isUnread: { isUnread(session) },
            onActivate: { activateSession(session) },
            onRestoreRequest: { restoreRequest = ArchivedRestoreRequest(target: .session(session)) },
            onRename: {
                renameTitle = session.title
                renamingSession = session
            },
            onArchive: { archiveChat(session) },
            onMarkRead: { store?.markRead(session) },
            onMarkUnread: {
                store?.markUnread(session)
                if selection == .session(serverId: session.serverId, id: session.id) {
                    selectNextChat(excluding: [session.id], serverId: session.serverId)
                }
            }
        )
    }

    private func isProjectVisuallyExpanded(_ id: UUID) -> Bool {
        draggingProjectID == nil && expanded.contains(id)
    }

    private func toggle(_ id: UUID) {
        withAnimation(.snappy(duration: 0.28)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func toggleWorkspace(_ id: UUID) {
        withAnimation(.snappy(duration: 0.28)) {
            if expandedWorkspaces.contains(id) {
                expandedWorkspaces.remove(id)
            } else {
                expandedWorkspaces.insert(id)
            }
        }
    }

    /// Activate a chat as soon as the primary pointer goes down. Keeping this
    /// as a row gesture (rather than an overlay) preserves child button and
    /// context-menu hit testing.
    private func sessionActivationGesture(_ session: ChatSession) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                activateSession(session)
            }
    }

    private func activateSession(_ session: ChatSession) {
        // Restoring/opening a chat whose workspace was archived revives the
        // workspace — layout intact. Routed through the environment so the
        // revival reaches the server too; a bare local save left other
        // devices (and the server's cascade) believing it was still archived.
        if let workspaceId = environment.workspaces.workspaceId(forSession: session.id),
            let workspace = environment.workspaces.workspace(id: workspaceId),
            workspace.isArchived
        {
            environment.unarchiveWorkspace(workspace)
            workspaceRevision += 1
        }
        let target = SidebarSelection.session(serverId: session.serverId, id: session.id)
        guard selection != target else { return }
        selection = target
    }

    @ViewBuilder
    private func reorderableSessionRow(_ session: ChatSession) -> some View {
        if order == .none {
            sessionRow(session, activatesOnMouseDown: false)
                .onDrag(
                    { sessionDragItemProvider(for: session) },
                    preview: {
                        sessionRow(session, isDragPreview: true)
                            .frame(width: 260)
                    }
                )
                .simultaneousGesture(sessionActivationGesture(session))
                .opacity(draggingSessionID == session.id ? 0 : 1)
                .onDrop(
                    of: [.text],
                    delegate: SessionDropDelegate(
                        sessionID: session.id,
                        draggingSessionID: $draggingSessionID,
                        moveSession: moveSession
                    )
                )
        } else {
            sessionRow(session)
        }
    }

    @ViewBuilder
    private func reorderableChronologicalSessionRow(
        _ session: ChatSession,
        project: Project,
        isNested: Bool = false
    ) -> some View {
        if order == .none {
            chronologicalSessionRow(session, project: project, isNested: isNested)
                .onDrag(
                    { sessionDragItemProvider(for: session) },
                    preview: {
                        chronologicalSessionRow(
                            session,
                            project: project,
                            isDragPreview: true,
                            isNested: isNested
                        )
                        .frame(width: 260)
                    }
                )
                .simultaneousGesture(sessionActivationGesture(session))
                .opacity(draggingSessionID == session.id ? 0 : 1)
                .onDrop(
                    of: [.text],
                    delegate: SessionDropDelegate(
                        sessionID: session.id,
                        draggingSessionID: $draggingSessionID,
                        moveSession: moveSession
                    )
                )
        } else {
            chronologicalSessionRow(session, project: project, isNested: isNested)
        }
    }

    private func sessionDragItemProvider(for session: ChatSession) -> NSItemProvider {
        draggingSessionID = session.id
        return NSItemProvider(object: session.id.uuidString as NSString)
    }

    private func orderedSessions(in project: Project) -> [ChatSession] {
        let sessions = list.sessions(in: project)
        guard order == .none else {
            return deferredSessionOrder.applying(
                to: automaticallySortedSessions.filter { $0.projectId == project.id },
                id: \.id
            )
        }
        return manuallyOrderedSessions(sessions, session: \.self)
    }

    /// Automatic priority/recency updates keep changing row content while the
    /// pointer is in the sidebar, but their identity order is held until the
    /// pointer leaves. Manual drag order bypasses these snapshots entirely.
    private func setAutomaticOrderDeferred(_ isDeferred: Bool) {
        if isDeferred {
            // The hover hold takes over any in-flight settle hold (the lock
            // is first-snapshot-wins, so the frozen order is preserved) and
            // owns it until the pointer leaves.
            cancelReorderSettleHold()
            deferredProjectOrder.lock(to: visibleProjects.map(\.id))
            deferredSessionOrder.lock(to: chronologicalSessions.map(\.id))
        } else {
            releaseDeferredOrder(animated: true)
        }
    }

    /// Coalesces bursts of automatic reorders. The first change of a burst
    /// commits immediately — it has already rendered by the time this runs —
    /// then the order freezes until the sort has been quiet for
    /// `ReorderSettle.quietDelay`, capped at `ReorderSettle.maxHold` under
    /// sustained churn. While the pointer is inside the sidebar the hover
    /// hold owns the lock instead, and pointer exit releases immediately.
    private func scheduleReorderSettleHold() {
        guard order != .none, !isPointerInsideSidebar else { return }
        if !deferredProjectOrder.isLocked, !deferredSessionOrder.isLocked {
            deferredProjectOrder.lock(to: visibleProjects.map(\.id))
            deferredSessionOrder.lock(to: chronologicalSessions.map(\.id))
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
        guard deferredProjectOrder.isLocked || deferredSessionOrder.isLocked else { return }
        if animated {
            withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
                deferredProjectOrder.unlock()
                deferredSessionOrder.unlock()
            }
        } else {
            deferredProjectOrder.unlock()
            deferredSessionOrder.unlock()
        }
    }

    private func archiveChat(_ session: ChatSession) {
        let archivedWorkspace = environment.archiveSessionAndWorkspaceIfEmpty(session)
        if selection == .session(serverId: session.serverId, id: session.id) {
            selectNextChat(excluding: [session.id], serverId: session.serverId)
        }
        if archivedWorkspace {
            workspaceRevision += 1
        }
    }

    private func sortedProjects(_ projects: [Project]) -> [Project] {
        projects.sorted(by: compareProjects)
    }

    private func compareProjects(_ left: Project, _ right: Project) -> Bool {
        if order == .updated {
            let leftPriority = projectPriority(for: left)
            let rightPriority = projectPriority(for: right)
            if leftPriority != rightPriority {
                return leftPriority.rawValue < rightPriority.rawValue
            }
        }
        let leftTimestamp = projectTimestamp(for: left)
        let rightTimestamp = projectTimestamp(for: right)
        if leftTimestamp != rightTimestamp {
            return leftTimestamp > rightTimestamp
        }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }

    private func compareSessions(_ left: ChatSession, _ right: ChatSession) -> Bool {
        if order == .updated {
            let leftPriority = sessionPriority(for: left)
            let rightPriority = sessionPriority(for: right)
            if leftPriority != rightPriority {
                return leftPriority.rawValue < rightPriority.rawValue
            }
        }
        let leftTimestamp = timestamp(for: left)
        let rightTimestamp = timestamp(for: right)
        if leftTimestamp != rightTimestamp {
            return leftTimestamp > rightTimestamp
        }
        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    }

    private func projectPriority(for project: Project) -> SidebarSessionPriority {
        projectOrderingKey(for: project).priority
    }

    /// Classifies a session into its sort tier. The checks MUST mirror
    /// `ChatSessionLeadingIcon`'s precedence (error → waiting → in progress →
    /// unread): a mid-run agent with buffered unread turns shows the spinner,
    /// not the badge, so it must sort as in progress too. Classifying it as
    /// unread made opening it silently drop it a tier — the row slid down on
    /// click with no visible state change. Rank order across tiers is
    /// `SidebarSessionPriority`; only classification follows the icon.
    private func sessionPriority(for session: ChatSession) -> SidebarSessionPriority {
        if store?.hasUnreadError(session) == true { return .errored }
        if store?.isWaitingOnUser(session) == true { return .waitingForUser }
        if store?.isInProgress(session) == true { return .inProgress }
        if unreadCount(for: session) != nil { return .unread }
        return .idle
    }

    /// The unread-turn count for a session's badge; nil when there is nothing
    /// to badge so the row falls through to the relative timestamp.
    private func unreadCount(for session: ChatSession) -> Int? {
        guard let count = store?.unreadCount(session), count > 0 else { return nil }
        return count
    }

    /// Whether the row is currently badged as unread, by either count or error.
    private func isUnread(_ session: ChatSession) -> Bool {
        unreadCount(for: session) != nil || store?.hasUnreadError(session) == true
    }

    private func timestamp(for session: ChatSession) -> Date {
        switch order {
        case .none:
            return session.sidebarStateChangedAt
        case .updated:
            return session.sidebarStateChangedAt
        case .created:
            return session.createdAt
        }
    }

    private func projectTimestamp(for project: Project) -> Date {
        switch order {
        case .none, .created:
            return project.createdAt
        case .updated:
            return projectOrderingKey(for: project).timestamp
        }
    }

    /// Computes the project tier and its recency in one pass. The old pair of
    /// helpers each fetched and sorted the same project sessions, multiplying
    /// work during every SwiftUI sidebar evaluation.
    private func projectOrderingKey(
        for project: Project
    ) -> (priority: SidebarSessionPriority, timestamp: Date) {
        guard order == .updated else { return (.idle, project.createdAt) }
        var leadingPriority: SidebarSessionPriority?
        var leadingTimestamp = project.createdAt
        for session in list.sessions
        where
            session.serverId == list.selectedServerId
            && session.projectId == project.id
            && !session.isArchived
            && (session.origin == .codevisor || list.showsImportedSessions)
        {
            let priority = sessionPriority(for: session)
            guard let currentPriority = leadingPriority else {
                leadingPriority = priority
                leadingTimestamp = session.sidebarStateChangedAt
                continue
            }
            if priority.rawValue < currentPriority.rawValue {
                leadingPriority = priority
                leadingTimestamp = session.sidebarStateChangedAt
            } else if priority == currentPriority,
                session.sidebarStateChangedAt > leadingTimestamp
            {
                leadingTimestamp = session.sidebarStateChangedAt
            }
        }
        return (leadingPriority ?? .idle, leadingTimestamp)
    }

    private func setOrder(_ newOrder: SidebarOrder) {
        guard newOrder != order else { return }
        if newOrder == .none {
            seedManualOrdersIfNeeded()
        }
        orderRaw = newOrder.rawValue
    }

    private func seedManualOrdersIfNeeded() {
        if projectOrder.isEmpty {
            saveProjectOrder(sortedProjects(list.activeProjects).map(\.id))
        }
        if sessionOrder.isEmpty {
            let sessions = list.activeProjects.flatMap { list.sessions(in: $0) }
            saveSessionOrder(sessions.sorted(by: compareSessions).map(\.id))
        }
    }

    private func resetManualOrder() {
        let sessions = list.activeProjects.flatMap { list.sessions(in: $0) }
        saveSessionOrder(
            sessions.sorted { left, right in
                let leftTimestamp = left.sidebarStateChangedAt
                let rightTimestamp = right.sidebarStateChangedAt
                if leftTimestamp != rightTimestamp { return leftTimestamp > rightTimestamp }
                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }.map(\.id))
    }

    private func moveProject(_ sourceID: UUID, before destinationID: UUID) {
        guard sourceID != destinationID else { return }
        var ids = visibleProjects.map(\.id)
        guard let sourceIndex = ids.firstIndex(of: sourceID),
            let destinationIndex = ids.firstIndex(of: destinationID)
        else { return }
        withAnimation(.snappy(duration: 0.22)) {
            let moved = ids.remove(at: sourceIndex)
            ids.insert(moved, at: destinationIndex)
            saveProjectOrder(ids)
        }
    }

    private func saveProjectOrder(_ ids: [UUID]) {
        manualProjectOrderRaw = ids.map(\.uuidString).joined(separator: "\n")
    }

    private func moveSession(_ sourceID: UUID, before destinationID: UUID) {
        guard sourceID != destinationID else { return }
        let sessions = list.activeProjects.flatMap { list.sessions(in: $0) }
        var ids = manuallyOrderedSessions(sessions, session: \.self).map(\.id)
        guard let sourceIndex = ids.firstIndex(of: sourceID),
            let destinationIndex = ids.firstIndex(of: destinationID)
        else { return }
        withAnimation(.snappy(duration: 0.22)) {
            let moved = ids.remove(at: sourceIndex)
            ids.insert(moved, at: destinationIndex)
            saveSessionOrder(ids)
        }
    }

    private func saveSessionOrder(_ ids: [UUID]) {
        manualSessionOrderRaw = ids.map(\.uuidString).joined(separator: "\n")
    }

    /// Applies persisted session ranks while placing chats that do not have a
    /// saved rank yet at the top. New chats are ordered newest-first until the
    /// next manual move persists their positions.
    private func manuallyOrderedSessions<Value>(
        _ values: [Value],
        session: KeyPath<Value, ChatSession>
    ) -> [Value] {
        let ranks = Dictionary(uniqueKeysWithValues: sessionOrder.enumerated().map { ($0.element, $0.offset) })
        return values.enumerated().sorted { left, right in
            let leftSession = left.element[keyPath: session]
            let rightSession = right.element[keyPath: session]
            let leftRank = ranks[leftSession.id]
            let rightRank = ranks[rightSession.id]
            switch (leftRank, rightRank) {
            case let (leftRank?, rightRank?): return leftRank < rightRank
            case (_?, nil): return false
            case (nil, _?): return true
            case (nil, nil):
                if leftSession.createdAt != rightSession.createdAt {
                    return leftSession.createdAt > rightSession.createdAt
                }
                return left.offset < right.offset
            }
        }.map(\.element)
    }

    /// Applies persisted ranks while keeping newly-created projects in the
    /// source's stable order at the end until the next manual move.
    private func manuallyOrdered<Value>(
        _ values: [Value],
        ids: [UUID],
        id: KeyPath<Value, UUID>
    ) -> [Value] {
        let ranks = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
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
}

#Preview {
    @Previewable @State var selection: SidebarSelection?
    return NavigationSplitView {
        SidebarView(selection: $selection)
            .environment(AppEnvironment.preview())
    } detail: {
        Text("Detail")
    }
    .frame(width: 900, height: 600)
}
