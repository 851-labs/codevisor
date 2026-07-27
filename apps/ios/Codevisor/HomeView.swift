import CodevisorCore
import CodevisorUI
import SwiftUI

/// How the home list groups chats — the iOS expression of the macOS sidebar's
/// organization filter.
private enum HomeOrganization: String, CaseIterable {
    case agents
    case byProject

    var title: String {
        switch self {
        case .agents: "Agents"
        case .byProject: "Projects"
        }
    }

    var symbolName: String {
        switch self {
        case .agents: "sparkles"
        case .byProject: "folder"
        }
    }
}

/// The main screen: every agent chat on the selected machine, grouped flat
/// (recency) or by project, with a machine picker and a filter menu. The iOS
/// counterpart of the macOS sidebar, laid out for touch.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment

    @AppStorage("home.organization") private var organizationRaw = HomeOrganization.agents.rawValue
    @State private var isAddingMachine = false
    @State private var isStartingChat = false
    @State private var path: [UUID] = []

    private var organization: HomeOrganization {
        HomeOrganization(rawValue: organizationRaw) ?? .agents
    }

    private var machines: MachineController { environment.machines }
    private var projectList: ProjectListModel { environment.projectList }

    /// Active chats on the selected machine, newest activity first.
    private var visibleSessions: [ChatSession] {
        projectList.sessions
            .filter { $0.serverId == machines.selectedMachineId && !$0.isArchived }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
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
            .navigationTitle("Codevisor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { machineMenu }
                ToolbarItem(placement: .topBarTrailing) { newChatButton }
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            .navigationDestination(for: UUID.self) { sessionId in
                WorkspaceScreen(sessionId: sessionId)
            }
            .refreshable {
                await projectList.refreshFromServer()
            }
            .sheet(isPresented: $isAddingMachine) {
                AddMachineSheet()
            }
            .sheet(isPresented: $isStartingChat) {
                NewChatSheet { session in
                    path.append(session.id)
                }
            }
        }
    }

    // MARK: - Lists

    private var sessionList: some View {
        List {
            switch organization {
            case .agents:
                Section {
                    ForEach(visibleSessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session, projectName: projectName(for: session))
                        }
                    }
                } header: {
                    machineStatusHeader
                }
            case .byProject:
                ForEach(projectList.activeProjects) { project in
                    let sessions = projectList.sessions(in: project).filter { !$0.isArchived }
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
    }

    private func projectName(for session: ChatSession) -> String? {
        projectList.activeProjects.first { $0.id == session.projectId }?.name
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Chats Yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Pair a machine, then your agents, workspaces, and projects appear here.")
        } actions: {
            Button("Add Machine") { isAddingMachine = true }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Toolbar

    private var machineMenu: some View {
        Menu {
            ForEach(machines.machines) { machine in
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
                isAddingMachine = true
            } label: {
                Label("Add Machine…", systemImage: "plus")
            }
        } label: {
            Label(
                machines.selectedMachine.name,
                systemImage: machines.selectedMachine.resolvedAppearance.symbolName
            )
            .labelStyle(.titleAndIcon)
        }
    }

    private var newChatButton: some View {
        Button {
            isStartingChat = true
        } label: {
            Image(systemName: "square.and.pencil")
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Group By", selection: $organizationRaw) {
                ForEach(HomeOrganization.allCases, id: \.rawValue) { organization in
                    Label(organization.title, systemImage: organization.symbolName)
                        .tag(organization.rawValue)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
    }

    private var machineStatusHeader: some View {
        HStack(spacing: 6) {
            let status = machines.statusByMachineId[machines.selectedMachineId]
            Circle()
                .fill(status?.isReachable == true ? .green : .orange)
                .frame(width: 7, height: 7)
            Text(status?.label ?? "Connecting…")
        }
        .font(.footnote)
        .textCase(nil)
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

/// Manual pairing: address + token, validated against the server before the
/// machine is saved. The QR/deeplink flow covers the common path; this is the
/// fallback for typing coordinates from `codevisor setup`.
private struct AddMachineSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var name = ""
    @State private var token = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address (host or host:port)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Name (optional)", text: $name)
                    SecureField("Connection token", text: $token)
                } footer: {
                    Text("Run `codevisor setup` on the machine to print its address and token.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(host.isEmpty || isAdding)
                }
            }
        }
    }

    private func add() {
        isAdding = true
        errorMessage = nil
        Task {
            do {
                let machine = try await environment.machines.addRemoteValidating(
                    host: host,
                    name: name.isEmpty ? nil : name,
                    token: token.isEmpty ? nil : token
                )
                environment.machines.selectMachine(machine.id)
                await environment.prepareSelectedMachine()
                dismiss()
            } catch {
                errorMessage = ErrorReporter.userFacingMessage(for: error)
                isAdding = false
            }
        }
    }
}

#Preview {
    HomeView()
        .environment(AppEnvironment.preview())
}
