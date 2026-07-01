import SwiftUI
import UniformTypeIdentifiers
import HerdManCore

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
    let workspace: Workspace

    var id: UUID { session.id }
}

/// Existing harness sessions found in a just-added workspace folder, pending
/// the user's decision to import them.
private struct PendingSessionImport: Identifiable {
    let workspace: Workspace
    let sessions: [ImportedSession]

    var id: UUID { workspace.id }
}

/// The sidebar: a New Chat action, a Projects section (with a + to add a
/// workspace) listing workspace folders and their sessions, and an archived
/// section.
///
/// Built on `ScrollView` + `LazyVStack` (not `List`), because the sidebar-styled
/// `List` outline coordinator crashes on the current macOS SDK.
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var selection: SidebarSelection?
    var store: SessionStore? = nil

    @State private var showingImporter = false
    @State private var showingRemoteMachine = false
    @State private var showingRemoteWorkspace = false
    @State private var renamingMachine: HerdManMachine?
    @State private var pendingImport: PendingSessionImport?
    @State private var expanded: Set<UUID> = []
    @State private var hovered: String?
    @State private var iconEditing: Workspace?
    @State private var draggingWorkspaceID: UUID?
    @AppStorage("sidebar.organization") private var organizationRaw = SidebarOrganization.byProject.rawValue
    @AppStorage("sidebar.order") private var orderRaw = SidebarOrder.updated.rawValue
    @AppStorage("sidebar.manualProjectOrder") private var manualProjectOrderRaw = ""
    @AppStorage("update.skippedVersion") private var skippedUpdateVersion = ""

    private var list: WorkspaceListModel { environment.workspaceList }
    private var organization: SidebarOrganization { SidebarOrganization(rawValue: organizationRaw) ?? .byProject }
    private var order: SidebarOrder { SidebarOrder(rawValue: orderRaw) ?? .updated }

    private var projectOrder: [UUID] {
        manualProjectOrderRaw
            .split(separator: "\n")
            .compactMap { UUID(uuidString: String($0)) }
    }

    private var visibleWorkspaces: [Workspace] {
        let active = list.activeWorkspaces
        guard organization == .byProject else {
            return sortedWorkspaces(active)
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
                return compareWorkspaces(left, right)
            }
        }
    }

    private var chronologicalSessions: [SidebarSessionListItem] {
        visibleWorkspaces
            .flatMap { workspace in
                list.sessions(in: workspace).map { SidebarSessionListItem(session: $0, workspace: workspace) }
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
                    onDismiss: { skippedUpdateVersion = release.version }
                )
                .padding(8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    actionRow("New chat", systemImage: "square.and.pencil", id: "new") {
                        selection = .newChat(nil)
                    }

                    projectsHeader

                    if organization == .byProject {
                        ForEach(visibleWorkspaces) { workspace in
                            workspaceFolder(workspace)
                                .onDrag {
                                    draggingWorkspaceID = workspace.id
                                    return NSItemProvider(object: workspace.id.uuidString as NSString)
                                }
                                .onDrop(
                                    of: [.text],
                                    delegate: WorkspaceDropDelegate(
                                        workspaceID: workspace.id,
                                        draggingWorkspaceID: $draggingWorkspaceID,
                                        moveWorkspace: moveWorkspace
                                    )
                                )
                        }
                    } else {
                        ForEach(chronologicalSessions) { item in
                            chronologicalSessionRow(item.session, workspace: item.workspace)
                        }
                    }
                    if visibleWorkspaces.isEmpty {
                        Text("Add a workspace with +")
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
                .padding(8)
                .animation(.snappy(duration: 0.22), value: visibleWorkspaces.map(\.id))
                .animation(.snappy(duration: 0.22), value: chronologicalSessions.map(\.id))
                .animation(.snappy(duration: 0.22), value: expanded)
            }
            .scrollContentBackground(.hidden)

            Divider()
            machinePicker
                .padding(8)
        }
        .background(.regularMaterial)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                let workspace = list.addWorkspace(folderURL: url)
                expanded.insert(workspace.id)
                selection = .newChat(workspace.id)
                offerSessionImport(for: workspace)
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
                environment.importSessions(pending.sessions, into: pending.workspace)
            }
            Button("Not Now", role: .cancel) {}
        } message: { pending in
            Text(importPromptMessage(for: pending))
        }
        .sheet(item: $iconEditing) { workspace in
            IconPickerView(currentSymbol: workspace.symbolName) { symbol in
                list.setIcon(symbol, for: workspace)
            }
        }
        .sheet(isPresented: $showingRemoteMachine) {
            RemoteMachineSheet { host, name in
                if (try? environment.machines.addRemote(host: host, name: name)) != nil {
                    selection = .newChat(nil)
                }
            }
        }
        .sheet(item: $renamingMachine) { machine in
            RenameMachineSheet(machine: machine) { name in
                try? environment.machines.renameMachine(machine.id, to: name)
            }
        }
        .sheet(isPresented: $showingRemoteWorkspace) {
            RemoteWorkspaceSheet { path in
                let workspace = list.addWorkspace(folderURL: URL(fileURLWithPath: path))
                expanded.insert(workspace.id)
                selection = .newChat(workspace.id)
                offerSessionImport(for: workspace)
            }
        }
    }

    /// After a workspace is added, look for existing harness sessions in its
    /// folder and — only when some are found — offer to import them.
    private func offerSessionImport(for workspace: Workspace) {
        Task {
            let importable = await environment.findImportableSessions(for: workspace.folderURL)
            guard !importable.isEmpty else { return }
            pendingImport = PendingSessionImport(workspace: workspace, sessions: importable)
        }
    }

    private func importPromptMessage(for pending: PendingSessionImport) -> String {
        let count = pending.sessions.count
        let chats = count == 1 ? "1 existing agent chat" : "\(count) existing agent chats"
        return "HerdMan found \(chats) in “\(pending.workspace.name)”. Import them to continue those conversations here."
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
            if !environment.machines.selectedMachine.isLocal {
                Button {
                    renamingMachine = environment.machines.selectedMachine
                } label: {
                    Label("Rename “\(environment.machines.selectedMachine.name)”…", systemImage: "pencil")
                }
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
            .background(rowBackground(id: "machine-picker", isSelected: false))
            .onHover { hovered = $0 ? "machine-picker" : (hovered == "machine-picker" ? nil : hovered) }
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
        .background(rowBackground(id: id, isSelected: false))
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
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
                        saveProjectOrder(sortedWorkspaces(list.activeWorkspaces).map(\.id))
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
                if environment.machines.selectedMachine.isLocal {
                    showingImporter = true
                } else {
                    showingRemoteWorkspace = true
                }
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add a workspace folder")
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Workspace rows

    @ViewBuilder
    private func workspaceFolder(_ workspace: Workspace) -> some View {
        let id = "folder-\(workspace.id)"
        let isHovered = hovered == id
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                // On hover the project icon becomes a disclosure chevron.
                ZStack {
                    Image(systemName: workspace.symbolName)
                        .foregroundStyle(.secondary)
                        .opacity(isHovered ? 0 : 1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.contains(workspace.id) ? 90 : 0))
                        .opacity(isHovered ? 1 : 0)
                }
                .frame(width: 18)
                Text(workspace.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 6)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(workspace.id) }

            if isHovered {
                Button {
                    expanded.insert(workspace.id)
                    selection = .newChat(workspace.id)
                } label: {
                    Image(systemName: "square.and.pencil").font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New chat in \(workspace.name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBackground(id: id, isSelected: false))
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .help(workspace.folderURL.path)
        .contextMenu {
            Button("New chat here") { selection = .newChat(workspace.id) }
            Button("Change icon") { iconEditing = workspace }
            Button("Archive") { list.archive(workspace) }
        }

        if expanded.contains(workspace.id) {
            ForEach(orderedSessions(in: workspace)) { session in
                sessionRow(session)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            if orderedSessions(in: workspace).isEmpty {
                Text("No sessions yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
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
        .background(rowBackground(id: id, isSelected: false))
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .onTapGesture(perform: toggle)
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        let id = "session-\(session.id)"
        let isSelected = selection == .session(session.id)
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(session.title).lineLimit(1)
                Spacer(minLength: 6)
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = .session(session.id) }

            // Fixed-size trailing slot so swapping the timestamp for the spinner
            // or archive button on hover doesn't change the row height.
            Group {
                if store?.isRunning(session.id) == true {
                    ProgressView().controlSize(.mini)
                } else if hovered == id {
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
        .padding(.leading, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(isSelected ? Color.primary : .secondary)
        .background(rowBackground(id: id, isSelected: isSelected))
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .contextMenu {
            Button("Archive") { list.archiveSession(session) }
        }
    }

    private func chronologicalSessionRow(_ session: ChatSession, workspace: Workspace) -> some View {
        let id = "chronological-session-\(session.id)"
        let isSelected = selection == .session(session.id)
        return HStack(spacing: 7) {
            Image(systemName: workspace.symbolName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(workspace.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Group {
                if store?.isRunning(session.id) == true {
                    ProgressView().controlSize(.mini)
                } else if hovered == id {
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
        .background(rowBackground(id: id, isSelected: isSelected))
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .onTapGesture { selection = .session(session.id) }
        .contextMenu {
            Button("Archive") { list.archiveSession(session) }
        }
    }

    @ViewBuilder
    private func rowBackground(id: String, isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.primary.opacity(0.14)
                  : (hovered == id ? Color.secondary.opacity(0.12) : .clear))
    }

    private func toggle(_ id: UUID) {
        withAnimation(.snappy(duration: 0.28)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func orderedSessions(in workspace: Workspace) -> [ChatSession] {
        list.sessions(in: workspace).sorted(by: compareSessions)
    }

    private func sortedWorkspaces(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.sorted(by: compareWorkspaces)
    }

    private func compareWorkspaces(_ left: Workspace, _ right: Workspace) -> Bool {
        let leftTimestamp = projectTimestamp(for: left)
        let rightTimestamp = projectTimestamp(for: right)
        if leftTimestamp != rightTimestamp {
            return leftTimestamp > rightTimestamp
        }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }

    private func compareSessions(_ left: ChatSession, _ right: ChatSession) -> Bool {
        let leftTimestamp = timestamp(for: left)
        let rightTimestamp = timestamp(for: right)
        if leftTimestamp != rightTimestamp {
            return leftTimestamp > rightTimestamp
        }
        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    }

    private func timestamp(for session: ChatSession) -> Date {
        switch order {
        case .updated:
            return session.updatedAt ?? session.createdAt
        case .created:
            return session.createdAt
        }
    }

    private func projectTimestamp(for workspace: Workspace) -> Date {
        guard order == .updated else { return workspace.createdAt }
        return list.sessions(in: workspace)
            .map { $0.updatedAt ?? $0.createdAt }
            .max() ?? workspace.createdAt
    }

    private func moveWorkspace(_ sourceID: UUID, before destinationID: UUID) {
        guard sourceID != destinationID else { return }
        var ids = visibleWorkspaces.map(\.id)
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

private struct WorkspaceDropDelegate: DropDelegate {
    let workspaceID: UUID
    @Binding var draggingWorkspaceID: UUID?
    let moveWorkspace: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingWorkspaceID, draggingWorkspaceID != workspaceID else { return }
        moveWorkspace(draggingWorkspaceID, workspaceID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingWorkspaceID = nil
        return true
    }
}

private struct RemoteMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var name = ""
    let onAdd: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add remote machine")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Address")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("mac-mini.tailnet.ts.net or 100.64.0.10:49361", text: $host)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Optional, e.g. Mac mini", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAdd(host, trimmedName.isEmpty ? nil : trimmedName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct RenameMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let machine: HerdManMachine
    let onRename: (String) -> Void

    init(machine: HerdManMachine, onRename: @escaping (String) -> Void) {
        self.machine = machine
        self.onRename = onRename
        _name = State(initialValue: machine.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename machine")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text(machine.baseURL.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onRename(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct RemoteWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    let onAdd: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add remote workspace")
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
