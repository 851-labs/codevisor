import CodevisorCore
import CodevisorUI
import SwiftUI

/// The New Workspace flow, matching macOS: pick a project and the workspace
/// opens immediately with a fresh chat pane — or browse the remote machine's
/// filesystem, Files-style, to turn any folder into a new project first.
struct NewWorkspaceSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Called with the created session so the caller can navigate into it.
    let onCreated: (ChatSession) -> Void

    private var projects: [Project] {
        // Recency: projects whose chats were touched most recently first —
        // the iOS stand-in for macOS's workspace-recency ordering.
        let sessions = environment.projectList.sessions
        var latest: [UUID: Date] = [:]
        for session in sessions {
            let stamp = session.updatedAt ?? session.createdAt
            if latest[session.projectId] == nil || latest[session.projectId]! < stamp {
                latest[session.projectId] = stamp
            }
        }
        return environment.projectList.activeProjects.sorted {
            (latest[$0.id] ?? .distantPast) > (latest[$1.id] ?? .distantPast)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !projects.isEmpty {
                    Section("Projects") {
                        ForEach(projects) { project in
                            Button {
                                create(in: project)
                            } label: {
                                projectRow(project)
                            }
                        }
                    }
                }
                Section {
                    NavigationLink(value: RemoteDirectory.home) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("New Project…")
                                    .foregroundStyle(.primary)
                                Text("Choose a folder on \(environment.machines.selectedMachine.name)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "folder.badge.plus")
                        }
                    }
                }
            }
            .navigationTitle("New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: RemoteDirectory.self) { directory in
                RemoteDirectoryScreen(directory: directory) { path in
                    createProject(at: path)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await environment.projectList.refreshFromServer()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func projectRow(_ project: Project) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .foregroundStyle(.primary)
                Text(abbreviatedPath(project.folderURL.path))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        } icon: {
            Image(systemName: project.symbolName)
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        if let range = path.range(of: "/Users/[^/]+", options: .regularExpression),
           range.lowerBound == path.startIndex {
            return "~" + path[range.upperBound...]
        }
        return path
    }

    /// Same as macOS `createWorkspaceSession(in:)`: mint the deferred session
    /// now (the agent spawns server-side on the first send) and jump straight
    /// into its chat pane.
    private func create(in project: Project) {
        let session = environment.projectList.newSession(in: project, title: "New Chat")
        dismiss()
        onCreated(session)
    }

    /// The browsed folder becomes a project, then a workspace in it —
    /// macOS's Browse-machine add-project flow in one step.
    private func createProject(at path: String) {
        let project = environment.projectList.addProject(folderURL: URL(fileURLWithPath: path))
        create(in: project)
    }
}

/// A spot in the remote filesystem: nil path = the machine's home directory
/// (the server resolves it on the first listing).
private struct RemoteDirectory: Hashable {
    let path: String?
    let name: String

    static let home = RemoteDirectory(path: nil, name: "Home")
}

/// One level of the remote filesystem, Files-style: folder rows that push
/// deeper, git repositories badged, hidden folders behind the ellipsis menu,
/// and a fixed call to action that turns the current folder into a project.
private struct RemoteDirectoryScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let directory: RemoteDirectory
    let onPick: (String) -> Void

    @State private var listing: ServerFsListing?
    @State private var errorMessage: String?
    @State private var showHidden = false

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
                    Label("Add “\(directory.name)” as Project", systemImage: "folder.badge.plus")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .padding(.bottom, 8)
            }
        }
        .task(id: showHidden) { await load() }
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
            listing = try await environment.serverClient.listDirectory(
                path: directory.path,
                showHidden: showHidden
            )
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }
}
