import CodevisorCore
import CodevisorUI
import SwiftUI

/// The New Workspace flow, matching macOS: a form — select a project
/// (checkmark, like the add-projects screens), optionally flip "Create New
/// Worktree", and confirm with the Create Workspace button. Browsing the
/// remote filesystem turns any folder into a new project and selects it.
/// The worktree choice is remembered per machine (like the last-used
/// harness) and seeds the next form; the chosen directory is the
/// workspace's one working directory for life.
struct NewWorkspaceSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Called with the created session so the caller can navigate into it.
    let onCreated: (ChatSession) -> Void

    @State private var navigationPath = NavigationPath()
    @State private var selectedProjectId: UUID?
    /// Whether Create Workspace materializes a fresh worktree for the
    /// selected (git) project instead of using the project folder.
    @State private var createInWorktree = false
    @State private var worktreeCreator = WorktreeCreator()
    /// The project whose worktree is being created (or failed); non-nil swaps
    /// the picker for the setup-progress view.
    @State private var creatingProject: Project?

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

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId } ?? projects.first
    }

    /// Worktrees only apply to git projects (as probed by the server).
    private var worktreeAvailable: Bool {
        selectedProject?.isGitRepository ?? false
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if creatingProject != nil {
                    worktreeProgress
                } else {
                    form
                }
            }
            .navigationTitle("New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: RemoteDirectory.self) { directory in
                RemoteDirectoryScreen(directory: directory) { path in
                    addProject(at: path)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(worktreeCreator.isRunning)
                }
            }
            .task {
                await environment.projectList.refreshFromServer()
            }
            // Start from the last workspace's worktree choice on this
            // machine — the same "last used" policy as the harness default.
            .task {
                createInWorktree = environment.composerDefaults
                    .prefersWorktreeForNewWorkspaces(
                        forServer: environment.machines.selectedMachineId
                    )
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(worktreeCreator.isRunning)
    }

    private var form: some View {
        List {
            if !projects.isEmpty {
                Section("Projects") {
                    ForEach(projects) { project in
                        Button {
                            selectedProjectId = project.id
                        } label: {
                            projectRow(project)
                        }
                    }
                }
            }
            Section {
                NavigationLink(value: RemoteDirectory.home) {
                    Label("New Project…", systemImage: "folder.badge.plus")
                        .foregroundStyle(.primary)
                }
            }
        }
        // The form's decision + confirmation live together in a fixed bottom
        // bar, HIG sheet-style: a plain toggle row above a full-width
        // prominent action button.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 14) {
                if !projects.isEmpty {
                    Toggle("Create New Worktree", isOn: $createInWorktree)
                        .disabled(!worktreeAvailable)
                }
                Button {
                    guard let project = selectedProject else { return }
                    create(in: project)
                } label: {
                    Text("Create Workspace")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedProject == nil)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }

    /// A plain, centered loading state while the worktree materializes: a
    /// spinner and a quiet caption. Only a failure expands into detail — the
    /// setup-phase row (error + streamed git logs) with retry/back.
    @ViewBuilder
    private var worktreeProgress: some View {
        if worktreeCreator.phase?.failureMessage == nil {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Creating Workspace…")
                    .font(.headline)
                Text("Setting up a git worktree in \(creatingProject?.name ?? "the project")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                worktreeLogTail
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 4) {
                        Text("Couldn't Create Workspace")
                            .font(.headline)
                        Text("The worktree could not be created")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let phase = worktreeCreator.phase {
                        SessionSetupView(phases: [phase])
                    }
                    HStack(spacing: 12) {
                        Button("Back") {
                            worktreeCreator.reset()
                            creatingProject = nil
                        }
                        .buttonStyle(.bordered)
                        Button("Try Again") {
                            guard let project = creatingProject else { return }
                            Task { await createWorktreeWorkspace(in: project) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// The last few streamed setup lines, console-quiet: dim monospace on a
    /// card, newest at the bottom. The failure state shows the full log.
    @ViewBuilder
    private var worktreeLogTail: some View {
        let lines = (worktreeCreator.phase?.logs ?? []).suffix(6)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines)) { line in
                    Text(line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .animation(.easeOut(duration: 0.15), value: worktreeCreator.phase?.logs.count)
            .accessibilityHidden(true)
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let isSelected = project.id == selectedProject?.id
        return HStack {
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
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func abbreviatedPath(_ path: String) -> String {
        if let range = path.range(of: "/Users/[^/]+", options: .regularExpression),
           range.lowerBound == path.startIndex {
            return "~" + path[range.upperBound...]
        }
        return path
    }

    /// Confirms the form — same as macOS `createWorkspaceSession(in:)`: mint
    /// the deferred session now (the agent spawns server-side on the first
    /// send) and jump straight into its chat pane. Worktree workspaces
    /// create their worktree eagerly, right here, and only exist once it
    /// materializes. Either way, the worktree choice becomes the machine's
    /// default for the next workspace.
    private func create(in project: Project) {
        let createsWorktree = createInWorktree && project.isGitRepository
        environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
            serverId: project.serverId,
            createsWorktree: createsWorktree
        )
        guard createsWorktree else {
            let session = environment.projectList.newSession(in: project, title: "New Chat")
            dismiss()
            onCreated(session)
            return
        }
        Task { await createWorktreeWorkspace(in: project) }
    }

    private func createWorktreeWorkspace(in project: Project) async {
        guard !worktreeCreator.isRunning else { return }
        creatingProject = project
        switch await worktreeCreator.create(
            projectId: project.id,
            client: environment.serverClient
        ) {
        case let .success(worktree):
            let session = environment.projectList.newSession(
                in: project,
                title: "New Chat",
                worktreeName: worktree.name,
                cwd: worktree.path
            )
            worktreeCreator.reset()
            creatingProject = nil
            dismiss()
            onCreated(session)
        case .failure:
            // The failed phase (message + logs) stays on screen with
            // Try Again/Back; no session was created.
            break
        }
    }

    /// The browsed folder becomes a project and the form's selection; the
    /// user confirms with Create Workspace like any other pick.
    private func addProject(at path: String) {
        let project = environment.projectList.addProject(folderURL: URL(fileURLWithPath: path))
        selectedProjectId = project.id
        navigationPath = NavigationPath()
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
