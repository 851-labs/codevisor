import SwiftUI
import CodevisorCore
import CodevisorUI

/// The workspace creation page — what the window shows on a fresh launch and
/// behind the sidebar's "New workspace". A form: pick a project (checkmark
/// selection, like the add-projects screen), optionally flip "Create new
/// worktree", and confirm with the Create Workspace button. The chosen
/// directory is the workspace's ONE working directory — every chat and
/// terminal it ever hosts runs there. The worktree choice is remembered per
/// machine (like the last-used harness) and seeds the next form.
struct NewWorkspaceView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    let store: SessionStore
    @Binding var selection: SidebarSelection?

    @State private var addProjectFlow = AddProjectFlow()
    /// Owned here (not by the panel) so staged clone work survives the
    /// project list changing underneath the page — same pattern as the
    /// old new-chat page.
    @State private var projectSetup = ProjectSetupModel()
    @State private var selectedProjectId: UUID?
    /// Whether Create Workspace materializes a fresh worktree for the
    /// selected (git) project instead of using the project folder.
    @State private var createInWorktree = false
    @State private var worktreeCreator = WorktreeCreator()
    /// The project whose worktree is being created (or failed); non-nil swaps
    /// the form for the setup-progress panel.
    @State private var creatingProject: Project?

    private var projects: [Project] {
        environment.projectList.activeProjectsByWorkspaceRecency(
            environment.workspaces.loadAll()
        )
    }

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId } ?? projects.first
    }

    /// Worktrees only apply to git projects (as probed by the server).
    private var worktreeAvailable: Bool {
        selectedProject?.isGitRepository ?? false
    }

    /// Inline setup while the machine has no projects (or a clone is midway).
    private var showsProjectSetup: Bool {
        projects.isEmpty || projectSetup.hasStagedWork
    }

    var body: some View {
        Group {
            if creatingProject != nil {
                worktreeProgress
            } else if showsProjectSetup {
                // First run on a machine: the onboarding-style setup panel.
                GeometryReader { geometry in
                    ScrollView {
                        ProjectSetupPanel(model: projectSetup) { project in
                            projectSetup = ProjectSetupModel()
                            selectedProjectId = project.id
                            create(in: project)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                    }
                }
            } else {
                page
            }
        }
        // A just-added project becomes the form's selection; the user
        // confirms with Create Workspace like any other pick.
        .addProjectFlow(addProjectFlow) { project in
            selectedProjectId = project.id
        }
        // Stale-while-revalidate: the persisted snapshot renders the list
        // immediately; the server refresh publishes any changes into it.
        .task {
            await environment.projectList.refreshFromServer()
        }
        // Start from the last workspace's worktree choice on this machine —
        // the same "last used" policy as the composer's harness default.
        .task(id: environment.machines.selectedMachineId) {
            createInWorktree = environment.composerDefaults
                .prefersWorktreeForNewWorkspaces(
                    forServer: environment.machines.selectedMachineId
                )
        }
        .id(environment.machines.selectedMachineId)
    }

    private var page: some View {
        // GeometryReader OUTSIDE the scroll view: it must measure the
        // viewport, not the scroll content (inside, its height is just the
        // minHeight floor and the content pins to the top).
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    // 2:3 spacer split sits the content slightly above true
                    // center — same optical placement as the old form page.
                    Spacer(minLength: 24)
                        .frame(maxHeight: .infinity)
                    VStack(spacing: 22) {
                        title
                        VStack(spacing: 8) {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)
                                ],
                                spacing: 8
                            ) {
                                ForEach(projects) { project in
                                    projectCard(project)
                                }
                            }
                            ProjectSetupActionCard(
                                systemImage: "folder.badge.plus",
                                title: "New project…",
                                subtitle: "Open a folder or clone a repository"
                            ) {
                                addProjectFlow.begin()
                            }
                        }
                        VStack(spacing: 14) {
                            worktreeToggle
                            createButton
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 24)
                    Spacer(minLength: 24)
                        .frame(maxHeight: .infinity)
                    Spacer(minLength: 0)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    private var title: some View {
        VStack(spacing: 6) {
            Text("New workspace")
                .font(.system(size: 26, weight: .semibold))
            Text("Pick a project to start in")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
        }
    }

    /// The form's one option: whether Create Workspace materializes a fresh
    /// git worktree. Disabled (not hidden — the form must not jump) when the
    /// selected project isn't a git repository.
    private var worktreeToggle: some View {
        Toggle("Create new worktree", isOn: $createInWorktree)
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!worktreeAvailable)
            .opacity(worktreeAvailable ? 1 : 0.5)
            .padding(.top, 8)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var createButton: some View {
        Button {
            guard let project = selectedProject else { return }
            create(in: project)
        } label: {
            Text("Create Workspace")
                .frame(minWidth: 140)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(selectedProject == nil)
    }

    /// A plain, centered loading state while the worktree materializes: a
    /// spinner, a quiet caption, and a dim tail of the streamed setup logs
    /// (git output, checkout hooks). Only a failure expands into detail —
    /// the setup-phase row (error + full logs) with retry/back.
    @ViewBuilder
    private var worktreeProgress: some View {
        if worktreeCreator.phase?.failureMessage == nil {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Creating workspace…")
                    .font(.headline)
                Text("Setting up a git worktree in \(creatingProject?.name ?? "the project")")
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
                worktreeLogTail
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("Couldn't create workspace")
                        .font(.system(size: 20, weight: .semibold))
                    Text("The worktree could not be created")
                        .font(.callout)
                        .foregroundStyle(theme.textSecondary)
                }
                if let phase = worktreeCreator.phase {
                    SessionSetupView(phases: [phase])
                        .frame(maxWidth: 460)
                }
                HStack(spacing: 12) {
                    Button("Back") {
                        worktreeCreator.reset()
                        creatingProject = nil
                    }
                    Button("Try Again") {
                        guard let project = creatingProject else { return }
                        Task { await createWorktreeWorkspace(in: project) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The last few streamed setup lines, console-quiet: dim monospace on a
    /// card, newest at the bottom. Progress stays legible without turning
    /// the loading state into a log viewer; the failure state shows the
    /// full log.
    @ViewBuilder
    private var worktreeLogTail: some View {
        let lines = (worktreeCreator.phase?.logs ?? []).suffix(6)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines)) { line in
                    Text(line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 460, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardQuietBackground)
            )
            .padding(.top, 6)
            .animation(.easeOut(duration: 0.15), value: worktreeCreator.phase?.logs.count)
            .accessibilityHidden(true)
        }
    }

    private func projectCard(_ project: Project) -> some View {
        ProjectCard(
            project: project,
            subtitle: ProjectSetupModel.abbreviatedPath(project.folderURL),
            isSelected: project.id == selectedProject?.id
        ) {
            selectedProjectId = project.id
        }
        .contextMenu {
            Button {
                environment.projectList.archive(project)
            } label: {
                Label("Archive", systemImage: "archivebox")
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    /// Confirms the form. Project-folder workspaces route through the
    /// quick-create page (`.newChat(project.id)` →
    /// `QuickWorkspaceCreationView`); worktree workspaces create their
    /// worktree eagerly, right here, and only exist once it materializes.
    /// Either way, the worktree choice becomes the machine's default for the
    /// next workspace.
    private func create(in project: Project) {
        let createsWorktree = createInWorktree && project.isGitRepository
        environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
            serverId: project.serverId,
            createsWorktree: createsWorktree
        )
        guard createsWorktree else {
            selection = .newChat(project.id)
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
            let session = store.createWorkspaceSession(in: project, worktree: worktree)
            worktreeCreator.reset()
            creatingProject = nil
            selection = .session(serverId: session.serverId, id: session.id)
        case .failure:
            // The failed phase (message + logs) stays on screen with
            // Try Again/Back; no workspace or session was created.
            break
        }
    }
}

/// One selectable project row-card: the setup grid's visual language
/// (icon + name + ~path) with the add-projects screen's selection treatment —
/// a trailing checkmark, tinted border, and selected background. Click =
/// select; the form's Create Workspace button confirms.
private struct ProjectCard: View {
    @Environment(\.theme) private var theme
    let project: Project
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: FilledSymbol.preferred(project.symbolName))
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(theme.rowSelectedBackground)
                            : isHovered
                                ? AnyShapeStyle(theme.cardHoverBackground)
                                : AnyShapeStyle(theme.cardBackground)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(project.name) — \(subtitle)")
        .accessibilityLabel("\(project.name), \(subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.snappy(duration: 0.15), value: isSelected)
    }
}
