import CodevisorCore
import CodevisorUI
import SwiftUI

/// Browse the machine's filesystem and turn a folder into a project — the
/// "New Project…" flow behind the composer's project picker (the browser
/// formerly lived in the New Workspace sheet).
struct AddProjectSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// The machine to browse and add on. Nil means the selected machine —
    /// the fleet-wide picker passes the machine the user picked.
    var serverId: String? = nil
    /// Called with the added project so the caller can select it.
    let onAdded: (Project) -> Void

    @State private var navigationPath = NavigationPath()

    private var targetServerId: String {
        serverId ?? environment.machines.selectedMachineId
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            RemoteDirectoryScreen(
                serverId: targetServerId,
                directory: .root,
                onOpen: { navigationPath.append($0) },
                onPick: addProject(at:)
            )
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: RemoteDirectory.self) { directory in
                RemoteDirectoryScreen(
                    serverId: targetServerId,
                    directory: directory,
                    onOpen: { navigationPath.append($0) },
                    onPick: addProject(at:)
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func addProject(at path: String) {
        Task {
            // Awaited so the returned record carries the server's git probe —
            // the picker offers the worktree step only for git repos.
            let project = await environment.projectList.addProject(
                folderURL: URL(fileURLWithPath: path),
                serverId: targetServerId,
                client: environment.machines.client(for: targetServerId)
            )
            dismiss()
            onAdded(project)
        }
    }
}

/// A spot in the remote filesystem.
struct RemoteDirectory: Hashable {
    let path: String?
    let name: String

    static let root = RemoteDirectory(path: "/", name: "Files")
}

/// One level of the remote filesystem, Files-style: folder rows that push
/// deeper, git repositories badged, secondary actions behind the ellipsis
/// menu, and a fixed call to action for the current folder.
struct RemoteDirectoryScreen: View {
    @Environment(AppEnvironment.self) private var environment
    /// The machine whose filesystem is browsed. Nil means the selected one.
    var serverId: String? = nil
    let directory: RemoteDirectory
    let onOpen: (RemoteDirectory) -> Void
    let onPick: (String) -> Void

    @State private var listing: ServerFsListing?
    @State private var errorMessage: String?
    @State private var showHidden = false
    @State private var showingNewFolder = false

    var body: some View {
        Group {
            if let listing {
                folderList(listing)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(errorMessage)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(directory.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingNewFolder = true
                    } label: {
                        Label("New Folder…", systemImage: "folder.badge.plus")
                    }
                    .disabled(listing == nil)
                    Divider()
                    Toggle("Show Hidden Folders", isOn: $showHidden)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Folder options")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let listing {
                Button {
                    onPick(listing.path)
                } label: {
                    Text("Choose")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.bottom, 8)
            }
        }
        .task(id: showHidden) { await load() }
        .sheet(isPresented: $showingNewFolder) {
            if let listing {
                NewRemoteFolderSheet(
                    machineName: machineName,
                    parentPath: listing.path,
                    existingNames: Set(listing.entries.map(\.name)),
                    create: { path in try await client.createDirectory(path: path) },
                    onCreated: didCreateFolder(at:)
                )
                .presentationDetents([.medium])
            }
        }
    }

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: serverId ?? environment.machines.selectedMachineId)
    }

    private var machineName: String {
        let targetServerId = serverId ?? environment.machines.selectedMachineId
        return environment.machines.machine(for: targetServerId)?.name
            ?? environment.machines.selectedMachine.name
    }

    private func didCreateFolder(at path: String) {
        Task { await load() }
        let name = (path as NSString).lastPathComponent
        onOpen(RemoteDirectory(path: path, name: name.isEmpty ? path : name))
    }

    private func folderList(_ listing: ServerFsListing) -> some View {
        List {
            if listing.entries.isEmpty {
                Text("No folders here")
                    .foregroundStyle(.secondary)
            }
            ForEach(listing.entries, id: \.path) { entry in
                NavigationLink(value: RemoteDirectory(path: entry.path, name: entry.name)) {
                    Label {
                        HStack {
                            Text(entry.name)
                            if entry.isGitRepo {
                                Spacer()
                                Text("GIT")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                        }
                    } icon: {
                        Image(systemName: entry.isGitRepo ? "folder.fill.badge.gearshape" : "folder.fill")
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
        // Clearance for the floating call to action.
        .contentMargins(.bottom, 64, for: .scrollContent)
    }

    private func load() async {
        do {
            listing = try await client.listDirectory(
                path: directory.path,
                showHidden: showHidden
            )
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }
}
