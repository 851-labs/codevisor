import CodevisorCore
import CodevisorUI
import SwiftUI

/// The composer's single run-target picker: a stepped sheet (like the model
/// picker) that walks machine → project → run location and closes. The chip
/// above the composer then renders just the run-location icon and project
/// name. Single-machine fleets skip straight to the project step; non-git
/// projects skip the run-location step.
struct RunTargetPickerSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// The machine the draft currently targets (preselected), nil when the
    /// draft has no project yet.
    var initialServerId: String? = nil
    /// The draft's current project, for the checkmark.
    var currentProject: Project? = nil
    var currentWantsWorktree = false
    /// Called with the picked project and whether the chat should run in a
    /// new worktree. The sheet dismisses itself right after.
    let onFinish: (Project, Bool) -> Void

    private enum Step {
        case machine
        case project
        case runLocation
    }

    @State private var step: Step = .machine
    @State private var pickedServerId: String?
    @State private var pickedProject: Project?
    @State private var isAddingProject = false

    /// Every machine's projects, most recently used first (scratch backing
    /// projects are internal and never listed).
    private var pickerProjects: [Project] {
        environment.projectList.fleetActiveProjectsByWorkspaceRecency(
            environment.workspaces.loadAll()
        )
        .filter { !$0.isScratch }
    }

    private var machines: [CodevisorMachine] {
        environment.machines.allMachines
    }

    private var scopedProjects: [Project] {
        pickerProjects.filter { $0.serverId == pickedServerId }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .machine: machineStep
                case .project: projectStep
                case .runLocation: runLocationStep
                }
            }
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            pickedServerId = initialServerId ?? machines.first?.id
            // One machine: nothing to choose, start at its projects.
            if machines.count <= 1 { step = .project }
        }
        .sheet(isPresented: $isAddingProject) {
            AddProjectSheet(serverId: pickedServerId) { project in
                advance(with: project)
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case .machine: "Machine"
        case .project: "Project"
        case .runLocation: "Run Location"
        }
    }

    // MARK: - Steps

    private var machineStep: some View {
        List {
            ForEach(machines) { machine in
                Button {
                    pickedServerId = machine.id
                    step = .project
                } label: {
                    row(
                        machine.name,
                        systemImage: EntitySystemSymbol.machine(machine),
                        isChecked: machine.id
                            == (pickedServerId ?? currentProject?.serverId)
                    )
                }
                .disabled(!pickerProjects.contains { $0.serverId == machine.id })
            }
        }
    }

    private var projectStep: some View {
        List {
            ForEach(scopedProjects) { project in
                Button {
                    advance(with: project)
                } label: {
                    row(
                        project.name,
                        systemImage: EntitySystemSymbol.project,
                        isChecked: currentProject?.serverId == project.serverId
                            && currentProject?.id == project.id
                    )
                }
            }
            Button {
                isAddingProject = true
            } label: {
                Label("New Project…", systemImage: "folder.badge.plus")
            }
        }
    }

    private var runLocationStep: some View {
        List {
            Button {
                finish(wantsWorktree: false)
            } label: {
                row(
                    "Project Directory",
                    systemImage: "folder.fill",
                    isChecked: isCurrentPick && !currentWantsWorktree
                )
            }
            Button {
                finish(wantsWorktree: true)
            } label: {
                row(
                    "New Worktree",
                    systemImage: "arrow.triangle.branch",
                    isChecked: isCurrentPick && currentWantsWorktree
                )
            }
        }
    }

    /// Whether the run-location step is showing the draft's CURRENT project
    /// (checkmarks only make sense then).
    private var isCurrentPick: Bool {
        pickedProject?.serverId == currentProject?.serverId
            && pickedProject?.id == currentProject?.id
    }

    // MARK: - Flow

    private func advance(with project: Project) {
        // Worktrees only exist for git projects; everything else runs in the
        // project directory and the sheet is done.
        guard project.isGitRepository else {
            pickedProject = project
            finish(wantsWorktree: false)
            return
        }
        pickedProject = project
        step = .runLocation
    }

    private func finish(wantsWorktree: Bool) {
        guard let pickedProject else { return }
        onFinish(pickedProject, wantsWorktree)
        dismiss()
    }

    private func row(_ title: String, systemImage: String, isChecked: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(Color.primary)
            Spacer()
            if isChecked {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }
}
