import SwiftUI
import CodevisorCore

/// What a fresh workspace opens showing: its eager chat's composer, a
/// terminal, or the New Tab picker page. The chat session always exists
/// (it's the workspace's sidebar presence and routing anchor) — this picks
/// the SELECTED tab.
enum WorkspaceStartingTab: String, CaseIterable {
    case chat
    case terminal
    case newTab

    var title: String {
        switch self {
        case .chat: "Chat"
        case .terminal: "Terminal"
        case .newTab: "Blank"
        }
    }
}

/// The workspace creation page — what the window shows on a fresh launch and
/// behind the sidebar's "New workspace". A small centered form, not a
/// composer: the decisions that must precede a workspace are where it runs
/// (everything hangs off the cwd), what it's called (the worktree takes the
/// same name), and what it opens showing.
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
    /// Prefilled from the famous-people pool; doubles as the worktree name
    /// when "New worktree" is on. Regenerated per page visit, not per keystroke.
    @State private var workspaceName = ""
    /// Off by default — worktrees are an explicit opt-in at the door.
    @State private var startInWorktree = false
    /// Which tab a new workspace opens on. Remembered per machine in the
    /// durable new-workspace defaults (file-backed, survives app updates).
    @State private var startingTab: WorkspaceStartingTab = .chat
    /// Runs creation (including materializing the worktree with its live
    /// setup log) and carries any failure for retry.
    @State private var creation = WorkspaceCreationModel()

    private var projects: [Project] { environment.projectList.activeProjects }

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId } ?? projects.first
    }

    /// Worktrees only exist for git projects; the toggle disables AND
    /// reads false for anything else.
    private var wantsWorktree: Bool {
        startInWorktree && selectedProject?.isGitRepository == true
    }

    /// Inline setup while the machine has no projects (or a clone is midway).
    private var showsProjectSetup: Bool {
        projects.isEmpty || projectSetup.hasStagedWork
    }

    private var trimmedName: String {
        workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if showsProjectSetup {
                // First run on a machine: the onboarding-style setup panel.
                GeometryReader { geometry in
                    ScrollView {
                        ProjectSetupPanel(model: projectSetup) { project in
                            projectSetup = ProjectSetupModel()
                            selectedProjectId = project.id
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
        .addProjectFlow(addProjectFlow) { project in
            selectedProjectId = project.id
        }
        // Stale-while-revalidate: the persisted snapshot renders the list
        // immediately; the server refresh publishes any changes into it.
        .task {
            await environment.projectList.refreshFromServer()
        }
        .task(id: environment.machines.selectedMachineId) {
            if workspaceName.isEmpty {
                workspaceName = WorkspaceNameGenerator.next(
                    excluding: takenWorkspaceNames
                )
            }
            // The page reopens as it was left (name excepted).
            if let remembered = environment.newWorkspaceDefaults.defaults(
                forServer: environment.machines.selectedMachineId
            ) {
                if let projectId = remembered.projectId,
                   projects.contains(where: { $0.id == projectId }) {
                    selectedProjectId = projectId
                }
                if let tab = remembered.startingTab.flatMap(WorkspaceStartingTab.init(rawValue:)) {
                    startingTab = tab
                }
                startInWorktree = remembered.newWorktree
            }
        }
        .id(environment.machines.selectedMachineId)
    }

    private var page: some View {
        // GeometryReader OUTSIDE the scroll view: it must measure the
        // viewport, not the scroll content (inside, its height is just the
        // minHeight floor and the form pins to the top).
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    // 2:3 spacer split sits the form slightly above true
                    // center — same optical placement as the old new-chat page.
                    Spacer(minLength: 24)
                        .frame(maxHeight: .infinity)
                    VStack(spacing: 22) {
                        title
                        if let phase = creation.phases.first {
                            // Progress takes the FORM's place: a terminal-
                            // styled live tail of the worktree's git/hook
                            // output, expanding with the pinned error on
                            // failure. (The chat transcript keeps its own
                            // SessionSetupView — this is page-only chrome.)
                            WorktreeCreationTail(
                                phase: phase,
                                worktreeName: WorkspaceNameGenerator.slug(from: trimmedName)
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                        } else {
                            form
                                .transition(.opacity)
                        }
                        VStack(spacing: 10) {
                            Button(action: create) {
                                Text(ctaTitle)
                                    .frame(minWidth: 160)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                            .disabled(trimmedName.isEmpty || selectedProject == nil || creation.isCreating)
                            if creation.hasFailure {
                                // Back to the form (different name, worktree
                                // off, …) without retrying blind.
                                Button("Edit Settings") { creation.reset() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .animation(.snappy(duration: 0.25), value: creation.phases.isEmpty)
                    .animation(.snappy(duration: 0.25), value: creation.isCreating)
                    .frame(maxWidth: 400)
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
        Text("New workspace")
            .font(.system(size: 26, weight: .semibold))
    }

    private var form: some View {
        VStack(spacing: 0) {
            formRow("Project") { projectPicker }
            rowDivider
            formRow("Name") {
                TextField("Name", text: $workspaceName, prompt: Text("Name"))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(theme.textPrimary)
            }
            rowDivider
            formRow("Mode") {
                Picker("Mode", selection: $startingTab) {
                    ForEach(WorkspaceStartingTab.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            rowDivider
            formRow("New worktree") {
                Toggle("New worktree", isOn: $startInWorktree)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    // Worktrees need git: the row stays (no layout jumps
                    // while flipping projects) but reads as unavailable.
                    .disabled(selectedProject?.isGitRepository != true)
            }
        }
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 16)
    }

    /// One settings-style row: label left, control right, native row metrics.
    private func formRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }

    /// The same project menu the composer uses: filled symbol icons, native
    /// selection checkmarks, "New project…" at the bottom.
    private var projectPicker: some View {
        Menu {
            ForEach(projects) { project in
                // Toggle for the native selected checkmark; MenuSymbolIcon
                // because AppKit menus drop plain SF Symbol images.
                Toggle(isOn: Binding(
                    get: { project.id == selectedProject?.id },
                    set: { isOn in
                        guard isOn else { return }
                        selectedProjectId = project.id
                        // Worktree choice doesn't carry onto projects that
                        // can't support it.
                        if !(project.isGitRepository) {
                            startInWorktree = false
                        }
                        Task { await environment.projectList.refreshFromServer() }
                    }
                )) {
                    Label {
                        Text(project.name)
                    } icon: {
                        // Same filled variant the sidebar rows use.
                        MenuSymbolIcon(systemName: FilledSymbol.preferred(project.symbolName))
                    }
                }
            }
            Divider()
            Button {
                addProjectFlow.begin()
            } label: {
                Label {
                    Text("New project…")
                } icon: {
                    MenuSymbolIcon(systemName: "folder.badge.plus")
                }
            }
        } label: {
            PickerChip(text: selectedProject?.name ?? "Choose…") {
                Image(
                    systemName: selectedProject.map {
                        FilledSymbol.preferred($0.symbolName)
                    } ?? "folder.fill"
                )
                .font(.system(size: 12))
            }
        }
        .menuStyle(.button)
        .buttonStyle(HoverIconButtonStyle(shape: .chip))
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Names already in use, so the prefill never collides.
    private var takenWorkspaceNames: Set<String> {
        Set(environment.workspaces.loadAll().map { $0.name.lowercased() })
    }

    private var ctaTitle: String {
        if creation.isCreating { return "Creating…" }
        return creation.hasFailure ? "Try Again" : "Create Workspace"
    }

    /// Creates the workspace — materializing the worktree FIRST when the
    /// toggle is on, so the workspace is born with the worktree as its root
    /// — remembers the settings for next time, and routes into it. On
    /// worktree failure the setup card stays with the error; the CTA
    /// becomes a retry.
    private func create() {
        guard let project = selectedProject, !trimmedName.isEmpty, !creation.isCreating else { return }
        let name = trimmedName
        let tab = startingTab
        let newWorktree = wantsWorktree
        Task {
            guard let session = await creation.create(
                project: project,
                name: name,
                startingTab: tab,
                newWorktree: newWorktree,
                store: store,
                environment: environment
            ) else { return }
            environment.newWorkspaceDefaults.remember(
                NewWorkspaceDefaultsStore.Defaults(
                    projectId: project.id,
                    startingTab: tab.rawValue,
                    newWorktree: newWorktree
                ),
                forServer: environment.machines.selectedMachineId
            )
            selection = .session(serverId: session.serverId, id: session.id)
        }
    }
}
