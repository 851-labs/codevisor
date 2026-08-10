import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore
import CodevisorTheming
import os
import CodevisorUI

private enum SidebarOrganization: String, CaseIterable {
    case compact
    case byWorkspace
    case byProject

    var title: String {
        switch self {
        case .compact: return "Agents"
        case .byWorkspace: return "Workspaces"
        case .byProject: return "Projects"
        }
    }
}

private enum SidebarOrder: String, CaseIterable {
    case none
    case updated
    case created

    var title: String {
        switch self {
        case .none: return "None"
        case .updated: return "Last updated"
        case .created: return "Created"
        }
    }
}

/// State groups used ahead of recency when the sidebar is ordered by last
/// updated. Lower values appear first: unread (finished, reviewable) chats
/// rank above in-progress (nothing to act on yet) ones. Note the tier a
/// session is *classified* into follows the leading icon's precedence, not
/// this rank order — see `sessionPriority(for:)`.
private enum SidebarSessionPriority: Int {
    case errored
    case waitingForUser
    case unread
    case inProgress
    case idle
}

private struct SidebarSessionListItem: Identifiable {
    let session: ChatSession
    let project: Project

    var id: UUID { session.id }
}

/// How many archived chats one page reveals.
private let archivedPageSize = 10

/// A pending "restore this?" confirmation. Clicking an archived row asks
/// before acting: the row looks exactly like a live one, so an unguarded click
/// would silently un-archive whatever the user was only trying to read.
private struct ArchivedRestoreRequest: Identifiable {
    enum Target {
        case project(Project)
        case session(ChatSession)
    }

    let target: Target

    var id: UUID {
        switch target {
        case let .project(project): project.id
        case let .session(session): session.id
        }
    }

    var name: String {
        switch target {
        case let .project(project): project.name
        case let .session(session): session.title
        }
    }

    var kind: String {
        switch target {
        case .project: "project"
        case .session: "chat"
        }
    }
}

/// A workspace row in either workspace-based mode. Its tabs and primary
/// session/project are resolved from the live session list so status and
/// activation reuse the session machinery.
private struct SidebarWorkspaceListItem: Identifiable {
    let workspace: Workspace
    let sessions: [ChatSession]
    let primarySession: ChatSession?
    let project: Project?

    var id: UUID { workspace.id }
}

/// Existing harness sessions found in a just-added project folder, pending
/// the user's decision to import them.
private struct PendingSessionImport: Identifiable {
    let project: Project
    let sessions: [ImportedSession]

    var id: UUID { project.id }
}

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
    private var developmentWorktreeColor: Color {
        guard let rgba = RGBA(hex: CodevisorAppVariant.developmentIconColorHex) else { return .blue }
        return Color(rgba: rgba)
    }
    private var developmentWorktreeForegroundColor: Color {
        let foregroundHex = ColorMath.pickReadableForeground(
            bg: CodevisorAppVariant.developmentIconColorHex,
            candidates: ["#ffffff", "#000000"]
        ) ?? "#ffffff"
        guard let rgba = RGBA(hex: foregroundHex) else { return .white }
        return Color(rgba: rgba)
    }

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
        return deferredProjectOrder.applying(to: sortedProjects(active), id: \.id)
    }

    /// Projects shown as folders in "by project": scratch backing projects
    /// (the single-use folder behind a no-project chat) are not projects —
    /// their chats render at the list root instead.
    private var projectSectionProjects: [Project] {
        visibleProjects.filter { !$0.isScratch }
    }

    /// Workspaces whose chats sit at the root of the "by project" list:
    /// scratch-backed ones, plus any whose project no longer resolves.
    private var looseWorkspaceItems: [SidebarWorkspaceListItem] {
        workspaceItems.filter { $0.project?.isScratch != false }
    }

    private var chronologicalSessions: [SidebarSessionListItem] {
        let sessions = visibleProjects
            .flatMap { project in
                list.sessions(in: project).map { SidebarSessionListItem(session: $0, project: project) }
            }
        if order != .none {
            let sorted = sessions.sorted { left, right in
                compareSessions(left.session, right.session)
            }
            return deferredSessionOrder.applying(to: sorted, id: \.id)
        }
        return manuallyOrderedSessions(sessions, session: \.session)
    }

    /// "By workspace": every workspace on the selected machine, ordered like
    /// the chronological chat list (via each workspace's primary chat), with
    /// session-less workspaces last by creation date.
    private var workspaceItems: [SidebarWorkspaceListItem] {
        _ = workspaceRevision
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
        return workspaces
            .map { workspace -> (item: SidebarWorkspaceListItem, rank: Int, created: Date) in
                let workspaceSessions = workspace.chatSessionIds.compactMap { sessionsById[$0]?.session }
                let primary = workspace.chatSessionIds.lazy.compactMap { sessionsById[$0] }.first
                // A legacy or draft CHAT-LESS workspace stays openable
                // through any session still routed to it by the grow-only
                // session index — archived ones included.
                let routingSession = primary?.session ?? list.sessions.first(where: {
                    $0.serverId == serverId
                        && environment.workspaces.workspaceId(forSession: $0.id) == workspace.id
                })
                let routingProject = primary?.project ?? routingSession.flatMap { fallback in
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
            }
            expandedWorkspaces.formUnion(workspaces.map(\.id))
        }
    }

    var body: some View {
        sidebarConfiguredView
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            if let release = environment.appUpdate.availableRelease,
               release.version != skippedUpdateVersion {
                UpdateBannerView(
                    model: environment.appUpdate,
                    release: release,
                    hasRunningChats: store?.hasActiveSessions(onServer: CodevisorMachine.local.id) ?? false
                )
                .padding(8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            // The selected remote machine's server has a newer release. (For
            // the local machine the app banner above covers app + server.)
            // Gated behind the local app being current: the user updates their
            // own machine before pushing updates to a remote one, so the two
            // banners are never shown at the same time.
            if environment.appUpdate.availableRelease == nil,
               let serverUpdate = environment.machines.selectedServerUpdate,
               serverUpdate.updateAvailable,
               !environment.machines.selectedMachine.isLocal,
               skippedServerUpdate != serverUpdateSkipKey(serverUpdate) {
                ServerUpdateBannerView(
                    machines: environment.machines,
                    machine: environment.machines.selectedMachine,
                    update: serverUpdate,
                    hasRunningChats: store?.hasActiveSessions(onServer: environment.machines.selectedMachineId) ?? false
                )
                .padding(8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Development identity + New chat + the Projects header stay
            // pinned; only the project/chat list itself scrolls.
            VStack(alignment: .leading, spacing: 1) {
                if CodevisorAppVariant.isDevelopment {
                    developmentWorktreeRow
                }

                actionRow("New chat", systemImage: "square.and.pencil") {
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
                    if organization == .byProject {
                        ForEach(projectSectionProjects) { project in
                            projectFolder(project)
                        }
                        // Chats without a real project (scratch-backed
                        // workspaces) sit at the root as plain chat rows —
                        // a single-use folder is not a project.
                        ForEach(looseWorkspaceItems) { item in
                            workspaceFolder(item, hierarchyDepth: 0)
                                .transition(.identity)
                        }
                    } else if organization == .byWorkspace {
                        ForEach(workspaceItems) { item in
                            workspaceFolder(item, hierarchyDepth: 0)
                                .transition(.identity)
                        }
                    } else {
                        ForEach(chronologicalSessions) { item in
                            reorderableChronologicalSessionRow(item.session, project: item.project)
                                .transition(.identity)
                        }
                    }
                    if organization == .byProject && projectSectionProjects.isEmpty
                        && looseWorkspaceItems.isEmpty {
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

    private var sidebarImportAndChatRenameAlertsView: some View {
        sidebarInteractionView
        .alert(
            "Import Existing Chats?",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            ),
            presenting: pendingImport
        ) { pending in
            Button("Import") {
                environment.importSessions(pending.sessions, into: pending.project)
            }
            Button("Not Now", role: .cancel) {}
        } message: { pending in
            Text(importPromptMessage(for: pending))
        }
        .alert(
            "Rename Chat",
            isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            ),
            presenting: renamingSession
        ) { session in
            TextField("Title", text: $renameTitle)
            Button("Rename") {
                let trimmed = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                list.renameSession(session, to: trimmed)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var sidebarRemainingAlertsView: some View {
        sidebarImportAndChatRenameAlertsView
        .alert(
            "Rename Workspace",
            isPresented: Binding(
                get: { renamingWorkspace != nil },
                set: { if !$0 { renamingWorkspace = nil } }
            ),
            presenting: renamingWorkspace
        ) { workspace in
            TextField("Name", text: $workspaceRenameTitle)
            Button("Rename") {
                let trimmed = workspaceRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                // An explicit rename pins the name so worktree creation does
                // not replace it.
                var renamed = workspace
                renamed.name = trimmed
                renamed.hasCustomName = true
                environment.workspaces.save(renamed)
                workspaceRevision += 1
            }
            Button("Cancel", role: .cancel) {}
        }
        // Archived rows are visually identical to live ones, so a click is
        // just as likely to be exploratory as intentional. Confirm before
        // pulling the item back into the sidebar.
        .alert(
            restoreAlertTitle,
            isPresented: Binding(
                get: { restoreRequest != nil },
                set: { if !$0 { restoreRequest = nil } }
            ),
            presenting: restoreRequest
        ) { request in
            Button("Restore") { performRestore(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("“\(request.name)” will move back into the sidebar.")
        }
    }

    private var sidebarChangeObserversView: some View {
        sidebarRemainingAlertsView
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
    }

    private var sidebarSheetsView: some View {
        sidebarChangeObserversView
        .sheet(item: $iconEditing) { project in
            IconPickerView(currentSymbol: project.symbolName) { symbol in
                list.setIcon(symbol, for: project)
            }
        }
        .sheet(item: $workspaceIconEditing) { workspace in
            IconPickerView(
                currentSymbol: workspace.symbolName ?? list.projects.first {
                    $0.id == workspace.projectId
                }?.symbolName ?? "square.grid.2x2"
            ) { symbol in
                var updated = workspace
                updated.symbolName = symbol
                environment.workspaces.save(updated)
                workspaceRevision += 1
            }
        }
        .sheet(isPresented: $showingRemoteMachine) {
            RemoteMachineSheet { host, name, token in
                do {
                    try await environment.machines.addRemoteValidating(host: host, name: name, token: token)
                    selection = .newChat(nil)
                    return nil
                } catch {
                    Log.machines.error("Adding remote machine failed: \(String(describing: error), privacy: .public)")
                    if case CodevisorServerClientError.httpStatus(401, _) = error {
                        return "That connection token was rejected by the machine."
                    }
                    return serverErrorMessage(error)
                }
            }
        }
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

    private var restoreAlertTitle: String {
        guard let restoreRequest else { return "Restore?" }
        return "Restore \(restoreRequest.kind)?"
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
        let ids: [UUID] = rawValue
            .split(separator: "\n")
            .compactMap { UUID(uuidString: String($0)) }
        return Set(ids)
    }

    /// One skip entry per machine + version, so dismissing one machine's
    /// server update doesn't hide another's.
    private func serverUpdateSkipKey(_ update: ServerUpdateInfo) -> String {
        "\(environment.machines.selectedMachineId):\(update.latestVersion)"
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

    private func importPromptMessage(for pending: PendingSessionImport) -> String {
        let count = pending.sessions.count
        let chats = count == 1 ? "1 existing agent chat" : "\(count) existing agent chats"
        return "Codevisor found \(chats) in “\(pending.project.name)”. Import them to continue those conversations here."
    }

    // MARK: - Header rows

    private var developmentWorktreeRow: some View {
        let worktreeName = CodevisorAppVariant.developmentWorktreeName
        return headerRow(
            worktreeName,
            systemImage: "ladybug.fill",
            foregroundColor: developmentWorktreeForegroundColor
        )
        .background(RoundedRectangle(cornerRadius: 6).fill(developmentWorktreeColor))
        .accessibilityLabel("Development worktree: \(worktreeName)")
        .help("Development worktree: \(worktreeName)")
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        headerRow(title, systemImage: systemImage)
            .contentShape(Rectangle())
            .sidebarRowHover(isEnabled: !isReordering)
            .onTapGesture(perform: action)
    }

    /// Shared geometry for the pinned sidebar items. The development identity
    /// row is informational, while action rows add their own hover and tap
    /// behavior on top of this label.
    private func headerRow(
        _ title: String,
        systemImage: String,
        foregroundColor: Color? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(foregroundColor ?? Color.secondary)
            Text(title)
                .foregroundStyle(foregroundColor ?? Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var projectsHeader: some View {
        HStack {
            Text({
                switch organization {
                case .byWorkspace: "Workspaces"
                case .compact: "Agents"
                case .byProject: "Projects"
                }
            }())
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
    @ViewBuilder
    private var sidebarFilterMenuContent: some View {
        Picker("Organization", selection: Binding(
            get: { organization },
            set: { organizationRaw = $0.rawValue }
        )) {
            ForEach(SidebarOrganization.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        Picker("Order by", selection: Binding(
            get: { order },
            set: { setOrder($0) }
        )) {
            ForEach(SidebarOrder.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        Divider()
        Toggle("Show Archived", isOn: $showArchived)
        if order == .none {
            Divider()
            Button("Reset manual order") {
                resetManualOrder()
            }
        }
    }

    // MARK: - Project rows

    @ViewBuilder
    private func projectFolder(_ project: Project) -> some View {
        reorderableProjectRow(project)

        // Keep the persisted disclosure state intact while making the list
        // compact enough to reorder. Ending the drag restores every folder
        // exactly as the user left it.
        if isProjectVisuallyExpanded(project.id) {
            let items = workspaceItems.filter { $0.workspace.projectId == project.id }
            ForEach(items) { item in
                workspaceFolder(item, hierarchyDepth: 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            if items.isEmpty {
                Text("No workspaces yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 16)
                    .padding(.vertical, 3)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func workspaceFolder(
        _ item: SidebarWorkspaceListItem,
        hierarchyDepth: Int
    ) -> some View {
        if item.sessions.count == 1, let session = item.sessions.first {
            sessionRow(session, hierarchyDepth: hierarchyDepth)
        } else {
            workspaceRow(
                item,
                isNested: hierarchyDepth > 0,
                isExpanded: expandedWorkspaces.contains(item.id),
                onToggle: { toggleWorkspace(item.id) }
            )

            if expandedWorkspaces.contains(item.id) {
                ForEach(item.sessions) { session in
                    sessionRow(session, hierarchyDepth: hierarchyDepth + 1)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
                if item.sessions.isEmpty {
                    Text("No tabs yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(
                            .leading,
                            8 + CGFloat(hierarchyDepth + 1) * hierarchyIndent + 24
                        )
                        .padding(.vertical, 3)
                        .transition(.opacity)
                }
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
        HoverableRow(
            isHoverEnabled: !isReordering,
            isHoverForced: isDragPreview
        ) { isHovered in
            HStack(spacing: 6) {
                // The disclosure toggle is a real Button (not an onTapGesture):
                // buttons resolve their hit target at mouse-down, so a click on
                // the hover new-chat button can never also flip the collapse
                // state — a row-level tap gesture used to fire for those clicks.
                Button {
                    // An archived project has no chats to disclose; the click
                    // offers to bring it back instead.
                    if isArchivedEntry {
                        restoreRequest = ArchivedRestoreRequest(target: .project(project))
                    } else {
                        toggle(project.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        // On hover the project icon becomes a disclosure chevron.
                        ZStack {
                            Image(systemName: FilledSymbol.preferred(project.symbolName))
                                .foregroundStyle(.secondary)
                                .opacity(isHovered && !isArchivedEntry ? 0 : 1)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isProjectVisuallyExpanded(project.id) ? 90 : 0))
                                // Archived rows keep their project icon: there
                                // is no disclosure behind them to hint at.
                                .opacity(isHovered && !isArchivedEntry ? 1 : 0)
                        }
                        .frame(width: 18)
                        Text(project.name)
                            .font(itemTitleFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Starting a chat in an archived project would resurrect it by
                // a side door, so that affordance is dropped here.
                if isHovered, !isArchivedEntry {
                    // Only open the new chat — never touch the disclosure
                    // state; the label button owns collapse/expand.
                    Button {
                        selection = .newChat(project.id)
                    } label: {
                        Image(systemName: "square.and.pencil").font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("New chat in \(project.name)")
                    .accessibilityLabel("New chat in \(project.name)")
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(project.folderURL.path)
        .contextMenu {
            if isArchivedEntry {
                Button {
                    restoreRequest = ArchivedRestoreRequest(target: .project(project))
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
            } else {
                Button("New chat here") { selection = .newChat(project.id) }
                Button("Change icon") { iconEditing = project }
                Button { list.archive(project) } label: {
                    Label("Archive", systemImage: "archivebox")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
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

    /// Reveals the next page of archived chats.
    ///
    /// The rows themselves are already in memory, so the spinner is not hiding
    /// a fetch — it acknowledges the click and covers the layout pass for the
    /// added rows, which is the part that can actually stutter on a large
    /// archive. Keeping it on screen for a beat also stops a rapid double
    /// click from jumping two pages before the first has drawn.
    private func showMoreArchivedRow(remaining: Int) -> some View {
        HStack(spacing: 6) {
            if isLoadingMoreArchived {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18)
            } else {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
            }
            Text(isLoadingMoreArchived ? "Loading…" : "Show \(min(remaining, archivedPageSize)) more")
                .font(itemTitleFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .sidebarRowHover(isEnabled: !isLoadingMoreArchived)
        .onTapGesture {
            guard !isLoadingMoreArchived else { return }
            isLoadingMoreArchived = true
            Task {
                // One runloop hop so the spinner actually renders before the
                // rows are added and SwiftUI re-lays out the list.
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
                    archivedVisibleCount += archivedPageSize
                }
                isLoadingMoreArchived = false
            }
        }
        .accessibilityLabel("Show more archived chats")
        .accessibilityAddTraits(.isButton)
    }

    /// Matches `projectsHeader` exactly — same font, color, and padding — so
    /// "Archived" reads as a peer of the Agents/Workspaces/Projects label
    /// rather than as another row in the list. The only addition is the
    /// disclosure chevron, since unlike that header this one collapses.
    private var archivedHeader: some View {
        HStack(spacing: 6) {
            Text("Archived")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            // The same chevron the transcript disclosures use: its rotation is
            // scoped to Motion.indicator so it leads the content reveal rather
            // than interpolating alongside the rows shifting beneath it.
            TranscriptDisclosureChevron(expanded: archivedExpanded)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { archivedExpanded.toggle() }
        .accessibilityLabel("Archived")
        .accessibilityAddTraits(.isButton)
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
        switch organization {
        case .compact:
            // The Agents list pairs each chat with its project subtitle.
            chronologicalSessionRow(session, project: project, isArchivedEntry: true)
        case .byProject, .byWorkspace:
            // Both nest chats under a heading, so the compact row is the match.
            sessionRow(session, isArchivedEntry: true)
        }
    }

    /// Restores a chat and revives its workspace, mirroring the archive
    /// policy in reverse (`archiveSessionAndWorkspaceIfEmpty`).
    private func restoreChat(_ session: ChatSession) {
        list.unarchiveSession(session)
        if let workspaceId = environment.workspaces.workspaceId(forSession: session.id),
           let workspace = environment.workspaces.workspace(id: workspaceId),
           workspace.isArchived {
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
        let isSelected = !isDragPreview
            && !isArchivedEntry
            && selection == .session(serverId: session.serverId, id: session.id)
        return HoverableRow(
            isSelected: isSelected,
            isHoverEnabled: !isReordering,
            isHoverForced: isDragPreview
        ) { isHovered in
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    // Same icon slot as project rows so titles align; the row's
                    // dimmer foreground tints the icon along with the text.
                    sessionLeadingIcon(
                        session,
                        activityColor: isSelected ? Color.primary : .secondary
                    )
                    .frame(width: 18)
                    Text(session.title)
                        .font(itemTitleFont)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                }

                // An archived chat has nothing left to archive, so the hover
                // affordance is suppressed rather than offering a no-op.
                sessionStatus(session, isHovered: isHovered && !isArchivedEntry)
            }
            .padding(.horizontal, 8)
            .padding(.leading, CGFloat(hierarchyDepth) * hierarchyIndent)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // A zero-distance drag begins on mouse-down, unlike a tap gesture,
            // which waits for mouse-up. Child controls (the hover archive
            // button) retain gesture precedence over this row gesture.
            .gesture(
                sessionActivationGesture(session),
                including: isArchivedEntry || isDragPreview || !activatesOnMouseDown ? .none : .all
            )
            .onTapGesture {
                if isArchivedEntry {
                    restoreRequest = ArchivedRestoreRequest(target: .session(session))
                    return
                }
                guard !activatesOnMouseDown else { return }
                activateSession(session)
            }
            .foregroundStyle(isSelected ? Color.primary : .secondary)
        }
        .contextMenu {
            if isArchivedEntry {
                Button {
                    restoreRequest = ArchivedRestoreRequest(target: .session(session))
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
            } else {
                Button {
                    renameTitle = session.title
                    renamingSession = session
                } label: {
                    Label("Rename", systemImage: "pencil")
                        .labelStyle(.titleAndIcon)
                }
                Button { archiveChat(session) } label: {
                    Label("Archive", systemImage: "archivebox")
                        .labelStyle(.titleAndIcon)
                }
                unreadToggleButton(session)
            }
        }
    }

    /// Flips between marking a chat unread and clearing an existing unread
    /// badge, so the menu never offers the state the row is already in.
    @ViewBuilder
    private func unreadToggleButton(_ session: ChatSession) -> some View {
        if isUnread(session) {
            Button { store?.markRead(session) } label: {
                Label("Mark as read", systemImage: "message")
                    .labelStyle(.titleAndIcon)
            }
        } else {
            Button {
                store?.markUnread(session)
                if selection == .session(serverId: session.serverId, id: session.id) {
                    selectNextChat(excluding: [session.id], serverId: session.serverId)
                }
            } label: {
                Label("Mark as unread", systemImage: "message.badge")
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    /// One workspace row, either top-level or nested beneath its project.
    /// Nested rows are disclosure-only; top-level workspace rows retain their
    /// primary-chat activation behavior.
    private func workspaceRow(
        _ item: SidebarWorkspaceListItem,
        isNested: Bool = false,
        isExpanded: Bool = false,
        onToggle: (() -> Void)? = nil
    ) -> some View {
        // Top-level workspace organization uses workspace selection styling.
        // A nested workspace is only a disclosure container; its child chat
        // owns selection instead.
        let routesSelectedSession: Bool = {
            guard case let .session(serverId, sessionId) = selection,
                  serverId == item.workspace.serverId else { return false }
            return environment.workspaces.workspaceId(forSession: sessionId) == item.workspace.id
        }()
        let isSelected = onToggle == nil && routesSelectedSession
        return HoverableRow(
            isSelected: isSelected,
            isHoverEnabled: !isReordering,
            isHoverForced: false
        ) { isHovered in
            HStack(spacing: 7) {
                if let onToggle {
                    Button(action: onToggle) {
                        HStack(spacing: 7) {
                            ZStack {
                                Image(systemName: FilledSymbol.preferred("square.grid.2x2"))
                                    .foregroundStyle(.secondary)
                                    .opacity(isHovered ? 0 : 1)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                    .opacity(isHovered ? 1 : 0)
                            }
                            .frame(width: 18)
                            Text(workspaceTitle(item, isNested: isNested))
                                .font(itemTitleFont)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(isExpanded ? "Collapse workspace" : "Expand workspace")
                    .accessibilityLabel(
                        isExpanded
                            ? "Collapse \(item.workspace.name)"
                            : "Expand \(item.workspace.name)"
                    )
                    if let session = item.primarySession, isHovered {
                        sessionStatus(
                            session,
                            isHovered: true,
                            onArchive: { archiveWorkspace(item) }
                        )
                    }
                } else {
                    Image(systemName: workspaceSymbol(item))
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(workspaceTitle(item, isNested: isNested))
                        .font(itemTitleFont)
                        .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if onToggle == nil, let session = item.primarySession {
                    sessionStatus(
                        session,
                        isHovered: isHovered,
                        onArchive: { archiveWorkspace(item) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.leading, isNested ? hierarchyIndent : 0)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? Color.primary : .secondary)
            .gesture(
                workspaceActivationGesture(item),
                including: onToggle == nil ? .all : .none
            )
            .onTapGesture {
                guard onToggle == nil else { return }
                guard let session = item.primarySession else { return }
                activateSession(session)
            }
        }
        .contextMenu {
            Button {
                workspaceRenameTitle = item.workspace.name
                renamingWorkspace = item.workspace
            } label: {
                Label("Rename", systemImage: "pencil")
                    .labelStyle(.titleAndIcon)
            }
            Button {
                workspaceIconEditing = item.workspace
            } label: {
                Label("Change Icon", systemImage: "app.grid")
                    .labelStyle(.titleAndIcon)
            }
            Button {
                archiveWorkspace(item)
            } label: {
                Label("Archive", systemImage: "archivebox")
                    .labelStyle(.titleAndIcon)
            }
        }
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
           environment.workspaces.workspaceId(forSession: sessionId) == workspace.id {
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

    /// The workspace's own icon; a workspace born before icons existed
    /// falls back to its project's, then to a generic glyph.
    private func workspaceSymbol(_ item: SidebarWorkspaceListItem) -> String {
        if let symbol = item.workspace.symbolName {
            return FilledSymbol.preferred(symbol)
        }
        if let project = item.project {
            return FilledSymbol.preferred(project.symbolName)
        }
        return "square.grid.2x2"
    }

    private func workspaceTitle(
        _ item: SidebarWorkspaceListItem,
        isNested: Bool
    ) -> String {
        guard !isNested, let project = item.project else {
            return item.workspace.name
        }
        guard let worktree = item.primarySession?.worktreeName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !worktree.isEmpty,
              worktree.localizedCaseInsensitiveCompare(project.name) != .orderedSame else {
            return project.name
        }
        return "\(project.name) · \(worktree)"
    }

    private func chronologicalSessionRow(
        _ session: ChatSession,
        project: Project,
        isDragPreview: Bool = false,
        isArchivedEntry: Bool = false
    ) -> some View {
        let isSelected = !isDragPreview
            && !isArchivedEntry
            && selection == .session(serverId: session.serverId, id: session.id)
        // Manual-order chat rows attach this gesture alongside their native
        // drag source so activation does not prevent drag-to-reorder.
        let activatesOnMouseDown = order != .none
        return HoverableRow(
            isSelected: isSelected,
            isHoverEnabled: !isReordering,
            isHoverForced: isDragPreview
        ) { isHovered in
            HStack(spacing: 7) {
                sessionLeadingIcon(session)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(itemTitleFont)
                        .lineLimit(1)
                    Text([project.name, session.worktreeName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                sessionStatus(session, isHovered: isHovered && !isArchivedEntry)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? Color.primary : .secondary)
            .gesture(
                sessionActivationGesture(session),
                including: !isArchivedEntry && activatesOnMouseDown ? .all : .none
            )
            .onTapGesture {
                if isArchivedEntry {
                    restoreRequest = ArchivedRestoreRequest(target: .session(session))
                    return
                }
                guard !activatesOnMouseDown else { return }
                activateSession(session)
            }
        }
        .contextMenu {
            if isArchivedEntry {
                Button {
                    restoreRequest = ArchivedRestoreRequest(target: .session(session))
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
            } else {
                Button {
                    renameTitle = session.title
                    renamingSession = session
                } label: {
                    Label("Rename", systemImage: "pencil")
                        .labelStyle(.titleAndIcon)
                }
                Button { archiveChat(session) } label: {
                    Label("Archive", systemImage: "archivebox")
                        .labelStyle(.titleAndIcon)
                }
                unreadToggleButton(session)
            }
        }
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

    /// Top-level workspace rows route through their primary chat. Match chat
    /// rows by doing that work on pointer-down; nested workspace rows remain
    /// disclosure-only and disable this gesture at the call site.
    private func workspaceActivationGesture(_ item: SidebarWorkspaceListItem) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard let session = item.primarySession else { return }
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
           workspace.isArchived {
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
    private func reorderableChronologicalSessionRow(_ session: ChatSession, project: Project) -> some View {
        if order == .none {
            chronologicalSessionRow(session, project: project)
                .onDrag(
                    { sessionDragItemProvider(for: session) },
                    preview: {
                        chronologicalSessionRow(session, project: project, isDragPreview: true)
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
            chronologicalSessionRow(session, project: project)
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
                to: sessions.sorted(by: compareSessions),
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
            deferredProjectOrder.lock(to: visibleProjects.map(\.id))
            deferredSessionOrder.lock(to: chronologicalSessions.map(\.id))
        } else {
            releaseDeferredOrder(animated: true)
        }
    }

    private func releaseDeferredOrder(animated: Bool) {
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

    /// `activityColor` mirrors the foreground style the calling row applies, so
    /// the rasterized working glyph matches the text beside it.
    @ViewBuilder
    private func sessionLeadingIcon(
        _ session: ChatSession,
        activityColor: Color = .secondary
    ) -> some View {
        ChatSessionLeadingIcon(session: session, store: store, activityColor: activityColor)
    }

    @ViewBuilder
    private func sessionStatus(
        _ session: ChatSession,
        isHovered: Bool,
        onArchive: (() -> Void)? = nil
    ) -> some View {
        if store?.hasUnreadError(session) != true, isHovered {
            Button {
                if let onArchive {
                    onArchive()
                } else {
                    archiveChat(session)
                }
            } label: {
                Image(systemName: "archivebox")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Archive chat")
            .accessibilityLabel("Archive \(session.title)")
            .frame(width: 24, height: 14, alignment: .trailing)
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
        list.sessions(in: project)
            .map(sessionPriority)
            .min { $0.rawValue < $1.rawValue }
            ?? .idle
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
            let sessions = list.sessions(in: project)
            guard let leadingPriority = sessions
                .map(sessionPriority)
                .min(by: { $0.rawValue < $1.rawValue })
            else { return project.createdAt }
            return sessions
                .filter { sessionPriority(for: $0) == leadingPriority }
                .map(\.sidebarStateChangedAt)
                .max() ?? project.createdAt
        }
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
        saveSessionOrder(sessions.sorted { left, right in
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

/// Herdr-inspired working glyph: its ten braille frames advance at roughly
/// eight steps per second in the harness icon's slot.
///
/// The frame cycle is a `CAKeyframeAnimation` on a layer's `contents`, NOT a
/// `TimelineView(.animation)` — the same lesson already recorded on
/// `ShimmeringText`, but with more bite here. A `TimelineView` re-evaluates its
/// body on the main run loop, so this indicator froze solid for the duration of
/// any main-thread hitch (notably the transcript rebuild on a tab switch),
/// which read as a broken spinner while every render-server-driven
/// `ProgressView` on screen kept turning. Discrete frame swapping cannot be
/// composited in pure SwiftUI at all — a `Timer` or `PhaseAnimator` stalls
/// exactly the same way — so the cycle is handed to CoreAnimation wholesale.
///
/// The trade is that the glyph must be rasterized against a known color instead
/// of inheriting the ambient foreground style, so callers pass the color their
/// surrounding row already uses.
struct AgentActivityIndicator: View {
    /// Matches what the enclosing row would have tinted the glyph.
    var color: Color = .secondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BrailleSpinnerLayer(color: color, isAnimated: !reduceMotion)
            .frame(width: BrailleSpinnerFrames.size.width, height: BrailleSpinnerFrames.size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Working")
            .help("Chat is working")
    }
}

/// The ten braille frames, pre-rasterized per (color, appearance, scale).
///
/// Bounded and tiny: at most a couple of colors per appearance, so a plain
/// dictionary needs no eviction policy.
@MainActor
private enum BrailleSpinnerFrames {
    static let glyphs = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static let size = CGSize(width: 14, height: 14)
    /// Eight steps per second, as before.
    static let cycleDuration = Double(glyphs.count) / 8

    private struct Key: Hashable {
        let color: Color
        let appearance: String
        let scale: CGFloat
    }

    private static var cache: [Key: [CGImage]] = [:]

    static func images(color: Color, scale: CGFloat) -> [CGImage] {
        let key = Key(
            color: color,
            appearance: NSApp.effectiveAppearance.name.rawValue,
            scale: scale
        )
        if let cached = cache[key] { return cached }
        let images = glyphs.compactMap { render($0, color: color, scale: scale) }
        // A partial set would animate a short, wrong cycle; don't cache it.
        guard images.count == glyphs.count else { return images }
        cache[key] = images
        return images
    }

    private static func render(_ glyph: String, color: Color, scale: CGFloat) -> CGImage? {
        let pixelsWide = Int(size.width * scale)
        let pixelsHigh = Int(size.height * scale)
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: pixelsWide,
                  pixelsHigh: pixelsHigh,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              )
        else { return nil }
        rep.size = NSSize(width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // `.primary`/`.secondary` resolve differently per appearance, so bake
        // them against the app's current one (as MenuIconRasterizer does).
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            let text = NSAttributedString(
                string: glyph,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: NSColor(color)
                ]
            )
            let bounds = text.boundingRect(
                with: NSSize(width: size.width, height: size.height),
                options: [.usesLineFragmentOrigin]
            )
            text.draw(at: NSPoint(
                x: (size.width - bounds.width) / 2,
                y: (size.height - bounds.height) / 2
            ))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

/// Hosts the pre-rasterized frames on a layer and cycles them in the render
/// server, so the animation is immune to main-thread stalls.
private struct BrailleSpinnerLayer: NSViewRepresentable {
    let color: Color
    let isAnimated: Bool

    private static let animationKey = "brailleFrames"

    @MainActor
    final class Coordinator {
        var appliedKey: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        // Rebuild only when something that changes the pixels or the timing
        // moves; this runs on every SwiftUI invalidation of the enclosing row.
        let key = "\(color.hashValue)-\(scale)-\(isAnimated)-\(NSApp.effectiveAppearance.name.rawValue)"
        guard context.coordinator.appliedKey != key else { return }
        context.coordinator.appliedKey = key

        let images = BrailleSpinnerFrames.images(color: color, scale: scale)
        guard let first = images.first else { return }
        layer.contentsScale = scale
        layer.removeAnimation(forKey: Self.animationKey)
        layer.contents = first
        guard isAnimated, images.count > 1 else { return }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = images
        animation.calculationMode = .discrete
        animation.duration = BrailleSpinnerFrames.cycleDuration
        animation.repeatCount = .infinity
        // Phase-align to an absolute grid so every spinner on screen steps in
        // lockstep regardless of when it mounted — the old absolute-time frame
        // derivation gave that for free, and losing it would be visible with
        // several running chats listed together.
        let now = CACurrentMediaTime()
        let phase = now.truncatingRemainder(dividingBy: animation.duration)
        animation.beginTime = layer.convertTime(now, from: nil) - phase
        layer.add(animation, forKey: Self.animationKey)
    }
}

/// Row chrome (hover highlight + selected background) with ROW-LOCAL hover
/// state, exposed to the content so rows can reveal hover-only controls.
/// Hover must not live on the sidebar itself: a single shared "which id is
/// hovered" string re-evaluated the entire sidebar body — re-sorting every
/// project and session — on every pointer enter/leave.
private struct HoverableRow<Content: View>: View {
    var isSelected = false
    var isHoverEnabled = true
    var isHoverForced = false
    @ViewBuilder var content: (_ isHovered: Bool) -> Content
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        let revealsHoverContent = isHoverEnabled && isHovered
        let showsHoverBackground = isHoverForced || revealsHoverContent
        content(revealsHoverContent)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.rowSelectedBackground
                        : (showsHoverBackground ? theme.rowHoverBackground : .clear))
            )
            .onHover { isHovered = $0 }
    }
}

/// The background-only variant for rows without hover-revealed content.
private struct SidebarRowHoverModifier: ViewModifier {
    var isSelected = false
    var isEnabled = true
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let showsHover = isEnabled && isHovered
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.rowSelectedBackground
                        : (showsHover ? theme.rowHoverBackground : .clear))
            )
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// Sidebar row hover/selection background with row-local hover state.
    fileprivate func sidebarRowHover(isSelected: Bool = false, isEnabled: Bool = true) -> some View {
        modifier(SidebarRowHoverModifier(isSelected: isSelected, isEnabled: isEnabled))
    }
}

private struct ProjectDropDelegate: DropDelegate {
    let projectID: UUID
    @Binding var draggingProjectID: UUID?
    let moveProject: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingProjectID, draggingProjectID != projectID else { return }
        moveProject(draggingProjectID, projectID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingProjectID = nil
        return true
    }
}

private struct SessionDropDelegate: DropDelegate {
    let sessionID: UUID
    @Binding var draggingSessionID: UUID?
    let moveSession: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingSessionID, draggingSessionID != sessionID else { return }
        moveSession(draggingSessionID, sessionID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingSessionID = nil
        return true
    }
}

/// A count-less notification badge for chats that changed while unopened.
struct UnreadBadge: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .accessibilityLabel("Unread chat")
    }
}

/// Higher-priority unread marker for an activity epoch that ended abnormally.
struct ErrorUnreadBadge: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel("Unread chat error")
            .help("This chat ended with an error")
    }
}

/// Attention marker for a chat blocked on a question or plan approval.
struct ActionRequiredIndicator: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color.opacity(0.18))
            .overlay {
                Circle().stroke(color, lineWidth: 1.25)
            }
            .frame(width: 10, height: 10)
            .accessibilityLabel("Action required")
            .help("This chat needs your response")
    }
}

/// Compact relative time like "9h", "2d", "now".
enum RelativeTime {
    static func short(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
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
