import CodevisorCore
import CodevisorUI
import SwiftUI

/// Browse the machine's filesystem and turn a folder into a project.
struct AddProjectSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// The machine to browse and add on. Nil means the selected machine —
    /// the fleet-wide picker passes the machine the user picked.
    var serverId: String? = nil
    /// Called with the added project so the caller can select it.
    let onAdded: (Project) -> Void

    @State private var navigationPath = NavigationPath()
    @State private var isAddingProject = false

    private var targetServerId: String {
        serverId ?? environment.machines.selectedMachineId
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            RemoteDirectoryScreen(
                serverId: targetServerId,
                directory: .root,
                onOpen: { navigationPath.append($0) },
                onPick: addProject(at:),
                isPicking: isAddingProject
            )
            .navigationDestination(for: RemoteDirectory.self) { directory in
                RemoteDirectoryScreen(
                    serverId: targetServerId,
                    directory: directory,
                    onOpen: { navigationPath.append($0) },
                    onPick: addProject(at:),
                    isPicking: isAddingProject
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isAddingProject)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isAddingProject)
    }

    private func addProject(at path: String) {
        guard !isAddingProject else { return }
        isAddingProject = true
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

    static let root = RemoteDirectory(path: "/", name: "Select Folder")
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
    var isPicking = false

    @State private var listing: ServerFsListing?
    @State private var errorMessage: String?
    @State private var showHidden = false
    @State private var showingNewFolder = false
    @State private var createdFolder: RemoteDirectory?
    @State private var loadGeneration = 0

    var body: some View {
        Group {
            if let listing {
                folderList(listing)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
            }
        }
        .task {
            guard listing == nil, errorMessage == nil else { return }
            await load()
        }
        .navigationTitle(directory.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isPicking)
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
                .disabled(isPicking)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let listing {
                Button {
                    onPick(listing.path)
                } label: {
                    ZStack {
                        Label(
                            "Add “\(directory.name)” as Project",
                            systemImage: "folder.badge.plus"
                        )
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .opacity(isPicking ? 0 : 1)
                        if isPicking {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(isPicking)
                .accessibilityLabel(
                    isPicking ? "Adding Project" : "Add \(directory.name) as Project"
                )
                .padding(.bottom, 8)
            }
        }
        .onChange(of: showHidden) { _, _ in
            Task { await load() }
        }
        .sheet(isPresented: $showingNewFolder, onDismiss: openCreatedFolderIfNeeded) {
            if let listing {
                newFolderSheet(for: listing)
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

    private func newFolderSheet(for listing: ServerFsListing) -> some View {
        let directoryClient = client
        return NewRemoteFolderSheet(
            machineName: machineName,
            parentPath: listing.path,
            existingNames: Set(listing.entries.map(\.name)),
            create: { path in try await directoryClient.createDirectory(path: path) },
            onCreated: didCreateFolder(at:)
        )
        .presentationDetents([.medium])
    }

    @MainActor
    private func didCreateFolder(at path: String) {
        let name = (path as NSString).lastPathComponent
        if var listing,
            !listing.entries.contains(where: { $0.path == path }),
            showHidden || !name.hasPrefix(".")
        {
            listing.entries.append(ServerFsEntry(name: name, path: path, isGitRepo: false))
            listing.entries.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            self.listing = listing
        }
        createdFolder = RemoteDirectory(path: path, name: name.isEmpty ? path : name)
    }

    @MainActor
    private func openCreatedFolderIfNeeded() {
        guard let createdFolder else { return }
        self.createdFolder = nil
        onOpen(createdFolder)
    }

    private func folderList(_ listing: ServerFsListing) -> some View {
        List {
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
        .contentMargins(.bottom, 64, for: .scrollContent)
        .overlay {
            if listing.entries.isEmpty {
                ContentUnavailableView(
                    "No Subfolders",
                    systemImage: "folder",
                    description: Text("Choose this folder or create a new one.")
                )
            }
        }
    }

    @MainActor
    private func load() async {
        loadGeneration += 1
        let requestGeneration = loadGeneration
        let requestedShowHidden = showHidden
        let directoryClient = client
        errorMessage = nil
        do {
            let loaded = try await directoryClient.listDirectory(
                path: directory.path,
                showHidden: requestedShowHidden
            )
            guard requestGeneration == loadGeneration else { return }
            listing = loaded
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == loadGeneration else { return }
            if listing == nil {
                errorMessage = ErrorReporter.userFacingMessage(for: error)
            }
        }
    }
}
