import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore
import CodevisorTheming
import os

private enum SidebarOrganization: String, CaseIterable {
    case chronological
    case byWorkspace
    case compact

    var title: String {
        switch self {
        case .chronological: return "By chat"
        case .byWorkspace: return "By workspace"
        case .compact: return "Nous"
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
/// updated. Lower values appear first.
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

/// A workspace row in "by workspace" mode. The primary session/project are
/// resolved from the live session list so status and activation reuse the
/// session machinery (the single-chat era: opening a workspace opens its
/// primary chat).
private struct SidebarWorkspaceListItem: Identifiable {
    let workspace: Workspace
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

/// The sidebar: a New Chat action, a Projects section (with a + to add a
/// project) listing project folders and their sessions, and an archived
/// section.
///
/// Built on `ScrollView` + `LazyVStack` (not `List`), because the sidebar-styled
/// `List` outline coordinator crashes on the current macOS SDK.
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Binding var selection: SidebarSelection?
    var store: SessionStore? = nil
    var publishesSceneActions = true

    @State private var addProjectFlow = AddProjectFlow()
    @State private var showingRemoteMachine = false
    @State private var pendingImport: PendingSessionImport?
    // Seeded from UserDefaults (same key as `expandedProjectsRaw`) so
    // per-project disclosure survives relaunch; written back via onChange
    // using the newline-separated UUID format `sidebar.manualProjectOrder`
    // already established.
    @State private var expanded: Set<UUID> = Set(
        (UserDefaults.standard.string(forKey: "sidebar.expandedProjects") ?? "")
            .split(separator: "\n")
            .compactMap { UUID(uuidString: String($0)) }
    )
    @State private var iconEditing: Project?
    @State private var renamingSession: ChatSession?
    @State private var renameTitle = ""
    @State private var renamingWorkspace: Workspace?
    @State private var workspaceRenameTitle = ""
    /// Bumped after workspace mutations (backfill sweep, renames) so the
    /// non-observable repository is re-read.
    @State private var workspaceRevision = 0
    @State private var draggingProjectID: UUID?
    @State private var draggingSessionID: UUID?
    @AppStorage("sidebar.organization") private var organizationRaw = SidebarOrganization.chronological.rawValue
    @AppStorage("sidebar.order") private var orderRaw = SidebarOrder.updated.rawValue
    @AppStorage("sidebar.manualProjectOrder") private var manualProjectOrderRaw = ""
    @AppStorage("sidebar.manualSessionOrder") private var manualSessionOrderRaw = ""
    @AppStorage("sidebar.expandedProjects") private var expandedProjectsRaw = ""
    @AppStorage("update.skippedVersion") private var skippedUpdateVersion = ""
    @AppStorage("update.skippedServerVersion") private var skippedServerUpdate = ""

    private var list: ProjectListModel { environment.projectList }
    private var organization: SidebarOrganization { SidebarOrganization(rawValue: organizationRaw) ?? .chronological }
    private var order: SidebarOrder { SidebarOrder(rawValue: orderRaw) ?? .updated }
    private var isReordering: Bool { draggingProjectID != nil || draggingSessionID != nil }
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
        guard order == .none else { return sortedProjects(active) }
        return manuallyOrdered(active, ids: projectOrder, id: \.id)
    }

    private var chronologicalSessions: [SidebarSessionListItem] {
        let sessions = visibleProjects
            .flatMap { project in
                list.sessions(in: project).map { SidebarSessionListItem(session: $0, project: project) }
            }
        guard order == .none else {
            return sessions.sorted { left, right in
                compareSessions(left.session, right.session)
            }
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
            uniqueKeysWithValues: sessionItems.enumerated().map { ($0.element.session.id, $0.offset) }
        )
        let sessionsById = Dictionary(uniqueKeysWithValues: sessionItems.map { ($0.session.id, $0) })
        let workspaces = environment.workspaces.loadAll().filter { $0.serverId == serverId }
        return workspaces
            .map { workspace -> (item: SidebarWorkspaceListItem, rank: Int, created: Date) in
                let primary = workspace.chatSessionIds.lazy.compactMap { sessionsById[$0] }.first
                // A CHAT-LESS workspace (every chat closed/archived) stays
                // openable through any session still routed to it by the
                // grow-only session index — archived ones included.
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

    /// Existing chats gain owning workspaces lazily; entering by-workspace
    /// mode sweeps the visible sessions so the list is complete. Idempotent
    /// and cheap after the first pass (indexed lookups).
    private func backfillWorkspaces() {
        guard organization == .byWorkspace else { return }
        for item in chronologicalSessions {
            _ = environment.workspaces.ensureWorkspace(
                for: WorkspaceSessionSeed(
                    sessionId: item.session.id,
                    title: item.session.title,
                    serverId: item.session.serverId,
                    projectId: item.project.id,
                    rootDirectory: item.session.cwd ?? item.project.folderURL.path
                ),
                legacyGroups: environment.paneGroups
            )
        }
        workspaceRevision += 1
    }

    var body: some View {
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
                    if organization == .byWorkspace {
                        ForEach(workspaceItems) { item in
                            workspaceRow(item)
                        }
                    } else {
                        ForEach(chronologicalSessions) { item in
                            reorderableChronologicalSessionRow(item.session, project: item.project)
                        }
                    }
                    if visibleProjects.isEmpty {
                        Text("Add a project with +")
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
                    } else if organization != .byWorkspace && chronologicalSessions.isEmpty {
                        Text("No sessions yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }

                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .animation(.snappy(duration: 0.22), value: visibleProjects.map(\.id))
                .animation(.snappy(duration: 0.22), value: chronologicalSessions.map(\.id))
                .animation(.snappy(duration: 0.22), value: expanded)
            }
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)

        }
        .background(theme.sidebarBackground)
        .addProjectFlow(addProjectFlow) { project in
            expanded.insert(project.id)
            selection = .newChat(project.id)
            offerSessionImport(for: project)
        }
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
                // An explicit rename pins the name (stops tracking the
                // primary chat's title).
                var renamed = workspace
                renamed.name = trimmed
                renamed.hasCustomName = true
                environment.workspaces.save(renamed)
                workspaceRevision += 1
            }
            Button("Cancel", role: .cancel) {}
        }
        // Entering by-workspace mode (or sessions changing while in it)
        // sweeps the visible chats so every one has an owning workspace.
        .onChange(of: organizationRaw, initial: true) { _, _ in
            backfillWorkspaces()
        }
        .onChange(of: chronologicalSessions.map(\.id)) { _, _ in
            backfillWorkspaces()
        }
        .sheet(item: $iconEditing) { project in
            IconPickerView(currentSymbol: project.symbolName) { symbol in
                list.setIcon(symbol, for: project)
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
        .onChange(of: expanded) { _, newValue in
            expandedProjectsRaw = newValue.map(\.uuidString).sorted().joined(separator: "\n")
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
                case .chronological, .compact: "Agents"
                }
            }())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
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
                if order == .none {
                    Divider()
                    Button("Reset manual order") {
                        resetManualOrder()
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .help("Organize projects")
            .accessibilityLabel("Organize projects")

            Button {
                startAddProject()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add a project folder")
            .accessibilityLabel("Add a project folder")
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Project rows

    @ViewBuilder
    private func projectFolder(_ project: Project) -> some View {
        reorderableProjectRow(project)

        if expanded.contains(project.id) {
            ForEach(orderedSessions(in: project)) { session in
                reorderableSessionRow(session)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            if orderedSessions(in: project).isEmpty {
                Text("No sessions yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    // Lines up with the session icons (8 row padding + 8 indent).
                    .padding(.leading, 16)
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

    private func projectRow(_ project: Project, isDragPreview: Bool = false) -> some View {
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
                    toggle(project.id)
                } label: {
                    HStack(spacing: 6) {
                        // On hover the project icon becomes a disclosure chevron.
                        ZStack {
                            Image(systemName: FilledSymbol.preferred(project.symbolName))
                                .foregroundStyle(.secondary)
                                .opacity(isHovered ? 0 : 1)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded.contains(project.id) ? 90 : 0))
                                .opacity(isHovered ? 1 : 0)
                        }
                        .frame(width: 18)
                        Text(project.name).fontWeight(.medium).lineLimit(1)
                        Spacer(minLength: 6)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isHovered {
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
            Button("New chat here") { selection = .newChat(project.id) }
            Button("Change icon") { iconEditing = project }
            Button { list.archive(project) } label: {
                Label("Archive", systemImage: "archivebox")
                    .labelStyle(.titleAndIcon)
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

    private func sessionRow(_ session: ChatSession, isDragPreview: Bool = false) -> some View {
        let isSelected = !isDragPreview
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
                    sessionLeadingIcon(session)
                        .frame(width: 18)
                    Text(session.title).lineLimit(1)
                    Spacer(minLength: 6)
                }

                sessionStatus(session, isHovered: isHovered)
            }
            .padding(.horizontal, 8)
            .padding(.leading, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // A zero-distance drag begins on mouse-down, unlike a tap gesture,
            // which waits for mouse-up. Child controls (the hover archive
            // button) retain gesture precedence over this row gesture.
            .gesture(sessionActivationGesture(session), including: order == .none ? .none : .all)
            .onTapGesture {
                guard order == .none else { return }
                activateSession(session)
            }
            .foregroundStyle(isSelected ? Color.primary : .secondary)
        }
        .contextMenu {
            Button {
                renameTitle = session.title
                renamingSession = session
            } label: {
                Label("Rename", systemImage: "pencil")
                    .labelStyle(.titleAndIcon)
            }
            Button { list.archiveSession(session) } label: {
                Label("Archive", systemImage: "archivebox")
                    .labelStyle(.titleAndIcon)
            }
            Button {
                store?.markUnread(session)
                if selection == .session(serverId: session.serverId, id: session.id) { selection = .newChat(nil) }
            } label: {
                Label("Mark as unread", systemImage: "message.badge")
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    /// One workspace in "by workspace" mode. Single-chat era: activation
    /// opens the primary chat (which IS the workspace); status/spinners come
    /// from that session.
    private func workspaceRow(_ item: SidebarWorkspaceListItem) -> some View {
        // Selected when ANY of its chats is routed — focus-follow moves the
        // selection between sibling chats, and the workspace row must not
        // flicker off when it lands on a non-primary one.
        let isSelected: Bool = {
            guard case let .session(serverId, sessionId) = selection,
                  serverId == item.workspace.serverId else { return false }
            return environment.workspaces.workspaceId(forSession: sessionId) == item.workspace.id
        }()
        return HoverableRow(
            isSelected: isSelected,
            isHoverEnabled: !isReordering,
            isHoverForced: false
        ) { isHovered in
            HStack(spacing: 7) {
                Image(systemName: "square.grid.2x2")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.workspace.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(workspaceSubtitle(item))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let session = item.primarySession {
                    sessionStatus(session, isHovered: isHovered)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? Color.primary : .secondary)
            .onTapGesture {
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
        }
    }

    private func workspaceSubtitle(_ item: SidebarWorkspaceListItem) -> String {
        var parts: [String] = []
        if let project = item.project { parts.append(project.name) }
        if let root = item.workspace.rootDirectory {
            let component = URL(fileURLWithPath: root).lastPathComponent
            if parts.last != component { parts.append(component) }
        }
        return parts.isEmpty ? "Workspace" : parts.joined(separator: " · ")
    }

    private func chronologicalSessionRow(
        _ session: ChatSession,
        project: Project,
        isDragPreview: Bool = false
    ) -> some View {
        let isSelected = !isDragPreview
            && selection == .session(serverId: session.serverId, id: session.id)
        // Manual-order Nous rows attach this gesture alongside their native
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
                        .font(.subheadline)
                        .lineLimit(1)
                    Text([project.name, session.worktreeName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                sessionStatus(session, isHovered: isHovered)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? Color.primary : .secondary)
            .gesture(
                sessionActivationGesture(session),
                including: activatesOnMouseDown ? .all : .none
            )
            .onTapGesture {
                guard !activatesOnMouseDown else { return }
                activateSession(session)
            }
        }
        .contextMenu {
            Button {
                renameTitle = session.title
                renamingSession = session
            } label: {
                Label("Rename", systemImage: "pencil")
                    .labelStyle(.titleAndIcon)
            }
            Button { list.archiveSession(session) } label: {
                Label("Archive", systemImage: "archivebox")
                    .labelStyle(.titleAndIcon)
            }
            Button {
                store?.markUnread(session)
                if selection == .session(serverId: session.serverId, id: session.id) { selection = .newChat(nil) }
            } label: {
                Label("Mark as unread", systemImage: "message.badge")
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private func toggle(_ id: UUID) {
        withAnimation(.snappy(duration: 0.28)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
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
        let target = SidebarSelection.session(serverId: session.serverId, id: session.id)
        guard selection != target else { return }
        selection = target
    }

    @ViewBuilder
    private func reorderableSessionRow(_ session: ChatSession) -> some View {
        if order == .none {
            sessionRow(session)
                .onDrag(
                    { sessionDragItemProvider(for: session) },
                    preview: {
                        sessionRow(session, isDragPreview: true)
                            .frame(width: 260)
                    }
                )
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
                .simultaneousGesture(
                    sessionActivationGesture(session),
                    including: organization == .compact ? .all : .none
                )
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
        guard order == .none else { return sessions.sorted(by: compareSessions) }
        return manuallyOrderedSessions(sessions, session: \.self)
    }

    @ViewBuilder
    private func sessionLeadingIcon(_ session: ChatSession) -> some View {
        if store?.hasUnreadError(session) == true {
            ErrorUnreadBadge(color: theme.statusError)
        } else if store?.isWaitingOnUser(session) == true {
            ActionRequiredIndicator(color: theme.statusError)
        } else if store?.isRunning(session) == true {
            AgentActivityIndicator()
        } else if unreadCount(for: session) != nil {
            UnreadBadge(color: notificationColor)
        } else {
            HarnessIcon(harnessId: session.harnessId, fallbackSymbolName: "bubble.left.fill")
        }
    }

    @ViewBuilder
    private func sessionStatus(_ session: ChatSession, isHovered: Bool) -> some View {
        if store?.hasUnreadError(session) == true {
            EmptyView()
        } else if organization != .compact || isHovered {
            // Fixed-size trailing slot so swapping the timestamp for the archive
            // button doesn't change the row height. Compact rows omit the slot
            // entirely when no control is visible.
            Group {
                if isHovered {
                    Button {
                        list.archiveSession(session)
                        if selection == .session(serverId: session.serverId, id: session.id) { selection = .newChat(nil) }
                    } label: {
                        Image(systemName: "archivebox")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Archive chat")
                    .accessibilityLabel("Archive \(session.title)")
                } else {
                    Text(RelativeTime.short(from: timestamp(for: session)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 24, height: 14, alignment: .trailing)
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

    private func sessionPriority(for session: ChatSession) -> SidebarSessionPriority {
        if store?.hasUnreadError(session) == true { return .errored }
        if store?.isWaitingOnUser(session) == true { return .waitingForUser }
        if unreadCount(for: session) != nil { return .unread }
        if store?.isInProgress(session) == true { return .inProgress }
        return .idle
    }

    /// The unread-turn count for a session's badge; nil when there is nothing
    /// to badge so the row falls through to the relative timestamp.
    private func unreadCount(for session: ChatSession) -> Int? {
        guard let count = store?.unreadCount(session), count > 0 else { return nil }
        return count
    }

    private func timestamp(for session: ChatSession) -> Date {
        switch order {
        case .none:
            return session.updatedAt ?? session.createdAt
        case .updated:
            return session.updatedAt ?? session.createdAt
        case .created:
            return session.createdAt
        }
    }

    private func projectTimestamp(for project: Project) -> Date {
        switch order {
        case .none, .created:
            return project.createdAt
        case .updated:
            return list.sessions(in: project)
                .map { $0.updatedAt ?? $0.createdAt }
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
            let leftTimestamp = left.updatedAt ?? left.createdAt
            let rightTimestamp = right.updatedAt ?? right.createdAt
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
/// eight steps per second in the harness icon's slot and foreground.
private struct AgentActivityIndicator: View {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.125, paused: reduceMotion)) { context in
            let frame = reduceMotion ? Self.frames[0] : Self.frame(at: context.date)
            Text(frame)
                .font(.system(size: 14, design: .monospaced))
                .contentTransition(.identity)
        }
        .frame(width: 14, height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
        .help("Chat is working")
    }

    private static func frame(at date: Date) -> String {
        let tick = Int(date.timeIntervalSinceReferenceDate * 8)
        return frames[tick % frames.count]
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
private struct UnreadBadge: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .accessibilityLabel("Unread chat")
    }
}

/// Higher-priority unread marker for an activity epoch that ended abnormally.
private struct ErrorUnreadBadge: View {
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
private struct ActionRequiredIndicator: View {
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
