import SwiftUI
import CodevisorCore

/// The workspace creation page — what the window shows on a fresh launch and
/// behind the sidebar's "New workspace". Just a project picker: click a
/// project card and the workspace exists (project name, rooted at the
/// project folder, opening on a new chat). Every other decision — worktree,
/// extra tabs — happens later, in context, where it's cheap to change.
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

    private var projects: [Project] {
        environment.projectList.activeProjectsByWorkspaceRecency(
            environment.workspaces.loadAll()
        )
    }

    /// Inline setup while the machine has no projects (or a clone is midway).
    private var showsProjectSetup: Bool {
        projects.isEmpty || projectSetup.hasStagedWork
    }

    var body: some View {
        Group {
            if showsProjectSetup {
                // First run on a machine: the onboarding-style setup panel.
                GeometryReader { geometry in
                    ScrollView {
                        ProjectSetupPanel(model: projectSetup) { project in
                            projectSetup = ProjectSetupModel()
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
        .addProjectFlow(addProjectFlow) { project in
            create(in: project)
        }
        // Stale-while-revalidate: the persisted snapshot renders the list
        // immediately; the server refresh publishes any changes into it.
        .task {
            await environment.projectList.refreshFromServer()
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

    private func projectCard(_ project: Project) -> some View {
        ProjectCard(
            project: project,
            subtitle: ProjectSetupModel.abbreviatedPath(project.folderURL)
        ) {
            create(in: project)
        }
    }

    /// Routes through the quick-create page (`.newChat(project.id)` →
    /// `QuickWorkspaceCreationView`): project name, project-folder
    /// root, straight into the new chat.
    private func create(in project: Project) {
        selection = .newChat(project.id)
    }
}

/// One clickable project row-card: the setup grid's visual language
/// (icon + name + ~path on `cardBackground`), but a plain ACTION — no
/// checkmark, no selection state. Click = create a workspace here.
private struct ProjectCard: View {
    @Environment(\.theme) private var theme
    let project: Project
    let subtitle: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: FilledSymbol.preferred(project.symbolName))
                    .font(.title3)
                    .foregroundStyle(.tint)
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
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isHovered
                            ? AnyShapeStyle(theme.cardHoverBackground)
                            : theme.cardBackground
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(project.name) — \(subtitle)")
        .accessibilityLabel("New workspace in \(project.name)")
    }
}
