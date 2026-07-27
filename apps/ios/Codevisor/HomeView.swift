import CodevisorCore
import CodevisorUI
import SwiftUI

/// How the workspace list groups chats — the same organization options as the
/// macOS sidebar. Workspaces on this client are 1:1 with chats today, so the
/// workspace grouping renders the same rows as Agents until multi-chat
/// workspaces sync.
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
/// left, the organize menu at the top right, and a fixed New Workspace call
/// to action at the bottom.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment

    @AppStorage("sidebar.organization") private var organizationRaw = HomeOrganization.compact.rawValue
    @AppStorage("sidebar.order") private var orderRaw = HomeOrder.updated.rawValue
    @AppStorage("sidebar.manualSessionOrder") private var manualSessionOrder = ""
    @State private var isShowingSettings = false
    @State private var isManagingMachines = false
    @State private var isStartingWorkspace = false
    @State private var path: [UUID] = []

    private var organization: HomeOrganization {
        HomeOrganization(rawValue: organizationRaw) ?? .compact
    }

    private var order: HomeOrder {
        HomeOrder(rawValue: orderRaw) ?? .updated
    }

    private var machines: MachineController { environment.machines }
    private var projectList: ProjectListModel { environment.projectList }

    /// Active chats on the selected machine, in the chosen order.
    private var visibleSessions: [ChatSession] {
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
                return (lhs.updatedAt ?? lhs.createdAt) > (rhs.updatedAt ?? rhs.createdAt)
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
                return (lhs.updatedAt ?? lhs.createdAt) > (rhs.updatedAt ?? rhs.createdAt)
            }
        }
    }

    private func priority(for session: ChatSession) -> Int {
        if session.hasUnreadError { return 0 }
        if session.actionRequired || session.pendingPlanApproval { return 1 }
        if session.unreadCount > 0 { return 2 }
        return 3
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if visibleSessions.isEmpty && projectList.activeProjects.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // One glass group on the left: settings, then the machine
                // picker, mirroring the macOS toolbar's machine menu.
                ToolbarItemGroup(placement: .topBarLeading) {
                    settingsButton
                    machineMenu
                }
                ToolbarItem(placement: .topBarTrailing) { organizeMenu }
            }
            .safeAreaInset(edge: .bottom) { newWorkspaceButton }
            .navigationDestination(for: UUID.self) { sessionId in
                WorkspaceScreen(sessionId: sessionId)
            }
            .refreshable {
                await projectList.refreshFromServer()
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsSheet()
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
            .sheet(isPresented: $isStartingWorkspace) {
                NewWorkspaceSheet { session in
                    path.append(session.id)
                }
            }
        }
    }

    // MARK: - Lists

    private var sessionList: some View {
        List {
            switch organization {
            case .compact, .byWorkspace:
                Section {
                    ForEach(visibleSessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session, projectName: projectName(for: session))
                        }
                    }
                    .onMove { source, destination in
                        // Drag-to-reorder only means something in manual
                        // order; other orders recompute on the next change.
                        guard order == .none else { return }
                        moveSessions(from: source, to: destination)
                    }
                }
            case .byProject:
                ForEach(projectList.activeProjects) { project in
                    let sessions = visibleSessions.filter { $0.projectId == project.id }
                    if !sessions.isEmpty {
                        Section {
                            ForEach(sessions) { session in
                                NavigationLink(value: session.id) {
                                    SessionRow(session: session, projectName: nil)
                                }
                            }
                        } header: {
                            Label(project.name, systemImage: project.symbolName)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Room for the floating call to action so the last row can scroll
        // clear of it.
        .contentMargins(.bottom, 64, for: .scrollContent)
    }

    private func moveSessions(from source: IndexSet, to destination: Int) {
        var ids = visibleSessions.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        manualSessionOrder = ids.map(\.uuidString).joined(separator: "\n")
    }

    private func projectName(for session: ChatSession) -> String? {
        projectList.activeProjects.first { $0.id == session.projectId }?.name
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Workspaces Yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Pair a machine in Settings, then your agents, workspaces, and projects appear here.")
        } actions: {
            Button("Open Settings") { isShowingSettings = true }
                .buttonStyle(.borderedProminent)
        }
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
            ForEach(machines.machines.filter { !$0.isLocal }) { machine in
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

    private var newWorkspaceButton: some View {
        Button {
            isStartingWorkspace = true
        } label: {
            Label("New workspace", systemImage: "plus")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .padding(.bottom, 8)
        .accessibilityLabel("New workspace")
    }
}

/// One chat row: status accent, title, project/worktree context, activity time.
private struct SessionRow: View {
    let session: ChatSession
    let projectName: String?

    private var needsAttention: Bool { session.actionRequired || session.pendingPlanApproval }
    private var hasError: Bool { session.hasUnreadError }
    private var isUnread: Bool { session.unreadCount > 0 }

    var body: some View {
        HStack(spacing: 10) {
            statusDot
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
            if let updatedAt = session.updatedAt {
                Text(updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusDot: some View {
        if hasError {
            Circle().fill(.red).frame(width: 8, height: 8)
        } else if needsAttention {
            Circle().fill(.orange).frame(width: 8, height: 8)
        } else if isUnread {
            Circle().fill(.blue).frame(width: 8, height: 8)
        } else {
            Circle().fill(.clear).frame(width: 8, height: 8)
        }
    }
}

#Preview {
    HomeView()
        .environment(AppEnvironment.preview())
}
