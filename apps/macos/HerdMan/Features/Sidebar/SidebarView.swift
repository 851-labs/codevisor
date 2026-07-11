import SwiftUI
import UniformTypeIdentifiers
import HerdManCore
import os

private enum SidebarOrganization: String, CaseIterable {
    case byProject
    case chronological

    var title: String {
        switch self {
        case .byProject: return "By project"
        case .chronological: return "Chronological"
        }
    }
}

private enum SidebarOrder: String, CaseIterable {
    case updated
    case created

    var title: String {
        switch self {
        case .updated: return "Last updated"
        case .created: return "Created"
        }
    }
}

private struct SidebarSessionListItem: Identifiable {
    let session: ChatSession
    let project: Project

    var id: UUID { session.id }
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
    @Environment(\.openSettings) private var openSettings
    @Environment(\.theme) private var theme
    @Binding var selection: SidebarSelection?
    var store: SessionStore? = nil
    var publishesSceneActions = true

    @State private var showingImporter = false
    @State private var showingRemoteMachine = false
    @State private var showingRemoteProject = false
    @State private var addMachineError: String?
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
    @State private var draggingProjectID: UUID?
    @AppStorage("sidebar.organization") private var organizationRaw = SidebarOrganization.byProject.rawValue
    @AppStorage("sidebar.order") private var orderRaw = SidebarOrder.updated.rawValue
    @AppStorage("sidebar.manualProjectOrder") private var manualProjectOrderRaw = ""
    @AppStorage("sidebar.expandedProjects") private var expandedProjectsRaw = ""
    @AppStorage("update.skippedVersion") private var skippedUpdateVersion = ""
    @AppStorage("update.skippedServerVersion") private var skippedServerUpdate = ""

    private var list: ProjectListModel { environment.projectList }
    private var organization: SidebarOrganization { SidebarOrganization(rawValue: organizationRaw) ?? .byProject }
    private var order: SidebarOrder { SidebarOrder(rawValue: orderRaw) ?? .updated }

    private var projectOrder: [UUID] {
        manualProjectOrderRaw
            .split(separator: "\n")
            .compactMap { UUID(uuidString: String($0)) }
    }

    private var visibleProjects: [Project] {
        let active = list.activeProjects
        guard organization == .byProject else {
            return sortedProjects(active)
        }

        let indexes = Dictionary(uniqueKeysWithValues: projectOrder.enumerated().map { ($0.element, $0.offset) })
        return active.sorted { left, right in
            let leftIndex = indexes[left.id]
            let rightIndex = indexes[right.id]
            switch (leftIndex, rightIndex) {
            case let (leftIndex?, rightIndex?):
                return leftIndex < rightIndex
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return compareProjects(left, right)
            }
        }
    }

    private var chronologicalSessions: [SidebarSessionListItem] {
        visibleProjects
            .flatMap { project in
                list.sessions(in: project).map { SidebarSessionListItem(session: $0, project: project) }
            }
            .sorted { left, right in
                compareSessions(left.session, right.session)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let release = environment.appUpdate.availableRelease,
               release.version != skippedUpdateVersion {
                UpdateBannerView(
                    model: environment.appUpdate,
                    release: release,
                    hasRunningChats: store?.hasActiveSessions(onServer: HerdManMachine.local.id) ?? false
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
            // New chat + the Projects header stay pinned; only the project
            // list itself scrolls.
            VStack(alignment: .leading, spacing: 1) {
                actionRow("New chat", systemImage: "square.and.pencil", id: "new") {
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
                        ForEach(visibleProjects) { project in
                            projectFolder(project)
                                .onDrag {
                                    draggingProjectID = project.id
                                    return NSItemProvider(object: project.id.uuidString as NSString)
                                }
                                .onDrop(
                                    of: [.text],
                                    delegate: ProjectDropDelegate(
                                        projectID: project.id,
                                        draggingProjectID: $draggingProjectID,
                                        moveProject: moveProject
                                    )
                                )
                        }
                    } else {
                        ForEach(chronologicalSessions) { item in
                            chronologicalSessionRow(item.session, project: item.project)
                        }
                    }
                    if visibleProjects.isEmpty {
                        Text("Add a project with +")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    } else if organization == .chronological && chronologicalSessions.isEmpty {
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

            Divider()
            machinePicker
                .padding(8)
        }
        .background(theme.sidebarBackground)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                let project = list.addProject(folderURL: url)
                expanded.insert(project.id)
                selection = .newChat(project.id)
                offerSessionImport(for: project)
            }
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
        .sheet(item: $iconEditing) { project in
            IconPickerView(currentSymbol: project.symbolName) { symbol in
                list.setIcon(symbol, for: project)
            }
        }
        .sheet(isPresented: $showingRemoteMachine) {
            RemoteMachineSheet { host, name, token in
                do {
                    try environment.machines.addRemote(host: host, name: name, token: token)
                    selection = .newChat(nil)
                } catch {
                    Log.machines.error("Adding remote machine failed: \(String(describing: error), privacy: .public)")
                    addMachineError = ErrorReporter.userFacingMessage(for: error)
                }
            }
        }
        .alert(
            "Couldn't Add the Machine",
            isPresented: Binding(
                get: { addMachineError != nil },
                set: { if !$0 { addMachineError = nil } }
            ),
            presenting: addMachineError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .sheet(isPresented: $showingRemoteProject) {
            RemoteProjectSheet { path in
                let project = list.addProject(folderURL: URL(fileURLWithPath: path))
                expanded.insert(project.id)
                selection = .newChat(project.id)
                offerSessionImport(for: project)
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

    /// Local machines pick a folder; remote machines prompt for a path.
    private func startAddProject() {
        if environment.machines.selectedMachine.isLocal {
            showingImporter = true
        } else {
            showingRemoteProject = true
        }
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
        return "HerdMan found \(chats) in “\(pending.project.name)”. Import them to continue those conversations here."
    }

    // MARK: - Header rows

    private var machinePicker: some View {
        Menu {
            ForEach(environment.machines.machines) { machine in
                Button {
                    environment.machines.selectMachine(machine.id)
                    selection = .newChat(nil)
                } label: {
                    if machine.id == environment.machines.selectedMachineId {
                        Label(machine.name, systemImage: "checkmark")
                    } else {
                        Text(machine.name)
                    }
                }
            }
            Divider()
            Button {
                showingRemoteMachine = true
            } label: {
                Label("Add remote machine…", systemImage: "plus")
            }
            Button {
                SettingsRouter.shared.selectedTab = .machines
                openSettings()
            } label: {
                Label("Manage machines…", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: environment.machines.selectedMachine.isLocal ? "desktopcomputer" : "network")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(environment.machines.selectedMachine.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(environment.machines.selectedMachine.baseURL.host ?? environment.machines.selectedMachine.baseURL.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .sidebarRowHover()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Select machine")
    }

    private func actionRow(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).frame(width: 18).foregroundStyle(.secondary)
            Text(title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .sidebarRowHover()
        .onTapGesture(perform: action)
    }

    private var projectsHeader: some View {
        HStack {
            Text("Projects")
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
                    set: { orderRaw = $0.rawValue }
                )) {
                    ForEach(SidebarOrder.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                if organization == .byProject {
                    Divider()
                    Button("Reset project order") {
                        saveProjectOrder(sortedProjects(list.activeProjects).map(\.id))
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

            Button {
                startAddProject()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add a project folder")
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Project rows

    @ViewBuilder
    private func projectFolder(_ project: Project) -> some View {
        HoverableRow { isHovered in
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

        if expanded.contains(project.id) {
            ForEach(orderedSessions(in: project)) { session in
                sessionRow(session)
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
        .sidebarRowHover()
        .onTapGesture(perform: toggle)
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        let isSelected = selection == .session(session.id)
        return HoverableRow(isSelected: isSelected) { isHovered in
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    // Same icon slot as project rows so titles align; the row's
                    // dimmer foreground tints the icon along with the text.
                    HarnessIcon(harnessId: session.harnessId, fallbackSymbolName: "bubble.left.fill")
                        .frame(width: 18)
                    Text(session.title).lineLimit(1)
                    Spacer(minLength: 6)
                }

                // Fixed-size trailing slot so swapping the timestamp for the spinner,
                // unread badge, or archive button on hover doesn't change the row height.
                Group {
                    if store?.isWaitingOnUser(session.id) == true {
                        // Blocked on the user (agent question / plan approval):
                        // the attention badge signals action required, not the
                        // "working" spinner that reads as the model being busy.
                        UnreadBadge()
                    } else if store?.isRunning(session.id) == true {
                        ProgressView().controlSize(.mini)
                    } else if isHovered {
                        Button {
                            list.archiveSession(session)
                            if selection == .session(session.id) { selection = .newChat(nil) }
                        } label: {
                            Image(systemName: "archivebox")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Archive chat")
                    } else if unreadCount(for: session) != nil {
                        UnreadBadge()
                    } else {
                        Text(RelativeTime.short(from: timestamp(for: session)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 24, height: 14, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.leading, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // A zero-distance drag begins on mouse-down, unlike a tap gesture,
            // which waits for mouse-up. Child controls (the hover archive
            // button) retain gesture precedence over this row gesture.
            .gesture(sessionActivationGesture(session.id))
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
                store?.markUnread(session.id)
                if selection == .session(session.id) { selection = .newChat(nil) }
            } label: {
                Label("Mark as unread", systemImage: "message.badge")
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private func chronologicalSessionRow(_ session: ChatSession, project: Project) -> some View {
        let isSelected = selection == .session(session.id)
        return HoverableRow(isSelected: isSelected) { isHovered in
            HStack(spacing: 7) {
                HarnessIcon(harnessId: session.harnessId, fallbackSymbolName: "bubble.left.fill")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(project.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Group {
                    if store?.isWaitingOnUser(session.id) == true {
                        // Blocked on the user (agent question / plan approval):
                        // the attention badge signals action required, not the
                        // "working" spinner that reads as the model being busy.
                        UnreadBadge()
                    } else if store?.isRunning(session.id) == true {
                        ProgressView().controlSize(.mini)
                    } else if isHovered {
                        Button {
                            list.archiveSession(session)
                            if selection == .session(session.id) { selection = .newChat(nil) }
                        } label: {
                            Image(systemName: "archivebox")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Archive chat")
                    } else if unreadCount(for: session) != nil {
                        UnreadBadge()
                    } else {
                        Text(RelativeTime.short(from: timestamp(for: session)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 24, height: 14, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? Color.primary : .secondary)
            .gesture(sessionActivationGesture(session.id))
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
                store?.markUnread(session.id)
                if selection == .session(session.id) { selection = .newChat(nil) }
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
    private func sessionActivationGesture(_ sessionID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                let target = SidebarSelection.session(sessionID)
                guard selection != target else { return }
                selection = target
            }
    }

    private func orderedSessions(in project: Project) -> [ChatSession] {
        list.sessions(in: project).sorted(by: compareSessions)
    }

    private func sortedProjects(_ projects: [Project]) -> [Project] {
        projects.sorted(by: compareProjects)
    }

    private func compareProjects(_ left: Project, _ right: Project) -> Bool {
        let leftTimestamp = projectTimestamp(for: left)
        let rightTimestamp = projectTimestamp(for: right)
        if leftTimestamp != rightTimestamp {
            return leftTimestamp > rightTimestamp
        }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }

    private func compareSessions(_ left: ChatSession, _ right: ChatSession) -> Bool {
        // In last-updated order, actively working sessions always float to
        // the top. Deliberately NOT `isRunning`: that includes the transient
        // connect pulse fired on every first open, which briefly floated the
        // just-clicked row and made the sidebar reorder-then-revert.
        if order == .updated {
            let leftRunning = store?.isActivelyWorking(left.id) == true
            let rightRunning = store?.isActivelyWorking(right.id) == true
            if leftRunning != rightRunning {
                return leftRunning
            }
        }
        let leftTimestamp = timestamp(for: left)
        let rightTimestamp = timestamp(for: right)
        if leftTimestamp != rightTimestamp {
            return leftTimestamp > rightTimestamp
        }
        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    }

    /// The unread-turn count for a session's badge; nil when there is nothing
    /// to badge so the row falls through to the relative timestamp.
    private func unreadCount(for session: ChatSession) -> Int? {
        guard let count = store?.unreadCount(session.id), count > 0 else { return nil }
        return count
    }

    private func timestamp(for session: ChatSession) -> Date {
        switch order {
        case .updated:
            return session.updatedAt ?? session.createdAt
        case .created:
            return session.createdAt
        }
    }

    private func projectTimestamp(for project: Project) -> Date {
        guard order == .updated else { return project.createdAt }
        return list.sessions(in: project)
            .map { $0.updatedAt ?? $0.createdAt }
            .max() ?? project.createdAt
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
}

/// Row chrome (hover highlight + selected background) with ROW-LOCAL hover
/// state, exposed to the content so rows can reveal hover-only controls.
/// Hover must not live on the sidebar itself: a single shared "which id is
/// hovered" string re-evaluated the entire sidebar body — re-sorting every
/// project and session — on every pointer enter/leave.
private struct HoverableRow<Content: View>: View {
    var isSelected = false
    @ViewBuilder var content: (_ isHovered: Bool) -> Content
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.rowSelectedBackground
                        : (isHovered ? theme.rowHoverBackground : .clear))
            )
            .onHover { isHovered = $0 }
    }
}

/// The background-only variant for rows without hover-revealed content.
private struct SidebarRowHoverModifier: ViewModifier {
    var isSelected = false
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.rowSelectedBackground
                        : (isHovered ? theme.rowHoverBackground : .clear))
            )
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// Sidebar row hover/selection background with row-local hover state.
    fileprivate func sidebarRowHover(isSelected: Bool = false) -> some View {
        modifier(SidebarRowHoverModifier(isSelected: isSelected))
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

// Internal: also used by NewChatView's "New project…" menu item.
struct RemoteProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    let onAdd: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add remote project")
                .font(.headline)
            TextField("/home/dylan/project", text: $path)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    onAdd(path)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!path.hasPrefix("/"))
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// A count-less notification badge for chats that changed while unopened.
private struct UnreadBadge: View {
    var body: some View {
        Circle()
            .fill(.blue)
            .frame(width: 8, height: 8)
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
