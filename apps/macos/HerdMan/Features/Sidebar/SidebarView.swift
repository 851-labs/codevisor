import SwiftUI
import UniformTypeIdentifiers
import HerdManCore

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
    @State private var expanded: Set<UUID> = []
    @State private var showArchived = false
    @State private var hovered: String?
    @State private var iconEditing: Workspace?

    private var list: WorkspaceListModel { environment.workspaceList }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    actionRow("New Chat", systemImage: "square.and.pencil", id: "new") {
                        selection = .newChat(nil)
                    }

                    projectsHeader

                    ForEach(list.activeWorkspaces) { workspace in
                        workspaceFolder(workspace)
                    }
                    if list.activeWorkspaces.isEmpty {
                        Text("Add a workspace with +")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }

                    if list.hasArchivedWorkspaces {
                        Spacer().frame(height: 8)
                        disclosureRow(id: "archived", title: "Archived", systemImage: "archivebox", isOpen: showArchived) {
                            showArchived.toggle()
                        }
                        if showArchived {
                            ForEach(list.archivedWorkspaces) { workspace in
                                archivedRow(workspace)
                            }
                        }
                    }
                }
                .padding(8)
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
            }
        }
        .sheet(item: $iconEditing) { workspace in
            IconPickerView(currentSymbol: workspace.symbolName) { symbol in
                list.setIcon(symbol, for: workspace)
            }
        }
        .sheet(isPresented: $showingRemoteMachine) {
            RemoteMachineSheet { host in
                if (try? environment.machines.addRemote(host: host)) != nil {
                    selection = .newChat(nil)
                }
            }
        }
        .sheet(isPresented: $showingRemoteWorkspace) {
            RemoteWorkspaceSheet { path in
                let workspace = list.addWorkspace(folderURL: URL(fileURLWithPath: path))
                expanded.insert(workspace.id)
                selection = .newChat(workspace.id)
            }
        }
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
                Label("Add Remote Machine…", systemImage: "plus")
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
            Button {
                if environment.machines.selectedMachine.isLocal {
                    showingImporter = true
                } else {
                    showingRemoteWorkspace = true
                }
            } label: {
                Image(systemName: "plus")
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
            if isHovered {
                Button {
                    expanded.insert(workspace.id)
                    selection = .newChat(workspace.id)
                } label: {
                    Image(systemName: "plus").font(.callout.weight(.semibold))
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
        .onTapGesture { toggle(workspace.id) }
        .help(workspace.folderURL.path)
        .contextMenu {
            Button("New Chat Here") { selection = .newChat(workspace.id) }
            Button("Change Icon…") { iconEditing = workspace }
            Button("Archive") { list.archive(workspace) }
            Divider()
            Button("Remove", role: .destructive) { list.removeWorkspace(workspace) }
        }

        if expanded.contains(workspace.id) {
            ForEach(list.sessions(in: workspace)) { session in
                sessionRow(session)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if list.sessions(in: workspace).isEmpty {
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
                    Text(RelativeTime.short(from: session.createdAt))
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

    private func archivedRow(_ workspace: Workspace) -> some View {
        HStack(spacing: 6) {
            Image(systemName: workspace.symbolName)
                .frame(width: 18)
                .foregroundStyle(.tertiary)
            Text(workspace.name).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .padding(.leading, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Unarchive") { list.unarchive(workspace) }
            Button("Remove", role: .destructive) { list.removeWorkspace(workspace) }
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
}

private struct RemoteMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    let onAdd: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Remote Machine")
                .font(.headline)
            TextField("mac-mini.tailnet.ts.net or 100.64.0.10:8765", text: $host)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    onAdd(host)
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

private struct RemoteWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    let onAdd: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Remote Workspace")
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
