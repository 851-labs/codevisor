import Autocomplete
import CodevisorCore
import CodevisorUI
import SwiftUI

extension NewChatView {
  enum RunPicker {
    case machine, project, location
  }

  enum ProjectPickerTarget: Hashable {
    case noProject
    case project(ProjectGroup.ID)
  }

  enum RunLocationPickerTarget: Hashable {
    case projectDirectory
    case newWorktree
    case manageProject
  }

  /// Hairline between two chips. It hides (instantly, like the hover fill
  /// itself) while either neighbour is hovered: the chip's hover capsule
  /// bleeds past its layout and would otherwise touch the line.
  func runPickerDivider(between leading: RunPicker, and trailing: RunPicker) -> some View {
    Divider()
      .frame(height: 14)
      .opacity(hoveredRunPicker == leading || hoveredRunPicker == trailing ? 0 : 1)
      .animation(nil, value: hoveredRunPicker)
      .accessibilityHidden(true)
  }

  private func trackHover(_ picker: RunPicker, _ hovering: Bool) {
    if hovering {
      hoveredRunPicker = picker
    } else if hoveredRunPicker == picker {
      hoveredRunPicker = nil
    }
  }

  /// The pickers only exist on the standalone page: they decide the
  /// workspace's one working directory, which is fixed the moment the
  /// first message creates it. Drafts inside an existing workspace always
  /// run in that workspace's directory.
  var showsRunPickers: Bool { paneDraftId == nil }

  /// Every machine's projects, most recently used first (scratch backing
  /// projects, when a server has any, are internal and never listed).
  private var pickerProjects: [Project] {
    environment.projectList.fleetActiveProjectsByWorkspaceRecency(
      environment.workspaces.loadAll()
    )
    .filter { !$0.isScratch }
  }

  /// The picker's entries for one machine: the linked projects that have
  /// a checkout there, one row per repository. The machine chip is the
  /// first choice, so the project list never reaches past it.
  private func pickerGroups(on serverId: String) -> [ProjectGroup] {
    environment.projectList.fleetActiveProjectGroupsByWorkspaceRecency(
      environment.workspaces.loadAll()
    )
    .filter { $0.member(on: serverId) != nil }
  }

  /// The machine picker shows only when there is a choice to make.
  var showsMachinePicker: Bool { environment.machines.allMachines.count > 1 }

  /// The live project record. The controller holds a snapshot from when
  /// the project was picked; the server's git probe lands on the list
  /// afterwards, and the worktree picker must follow the probed value.
  func liveProject(for controller: SessionController) -> Project {
    environment.projectList.projects.first {
      $0.serverId == controller.project.serverId && $0.id == controller.project.id
    } ?? controller.project
  }

  /// Choose the machine this chat runs on. Picking one re-points the draft
  /// at that machine's remembered (or most recent) project; the project
  /// picker then lists that machine's projects.
  func machinePicker(_ controller: SessionController) -> some View {
    let machines = environment.machines.allMachines
    let selectedServerId = controller.project.serverId
    let selectedMachine = environment.machines.machine(for: selectedServerId)
    let selection = Binding(
      get: { controller.project.serverId },
      set: { id in
        guard let machine = environment.machines.machine(for: id) else { return }
        selectTargetMachine(machine, controller: controller)
      }
    )
    return RunPickerMenu(
      chipText: selectedMachine?.name ?? "Machine",
      chipSymbol: selectedMachine.map(EntitySystemSymbol.machine) ?? EntitySystemSymbol.machine(.local)
    ) {
      Autocomplete.Picker("Machines", selection: selection, options: machines) { machine in
        Autocomplete.Choice(machine.name, value: machine.id, systemImage: EntitySystemSymbol.machine(machine))
      }
      .favorites($favoriteMachineIDs)
      .labelsHidden()
      Autocomplete.Section(id: "actions") {
        Autocomplete.Action("Manage Machines…", systemImage: "gearshape") {
          SettingsRouter.shared.showMachines()
          openSettings()
        }
        .help("Open Machine Settings")
      }
    }
    .autocompleteSearchLabel("Search machines")
    .autocompleteEmptyMessage("No matching machines")
    .onHover { trackHover(.machine, $0) }
    .help("Choose which machine this chat runs on")
    .accessibilityLabel("Machine")
    .accessibilityValue(selectedMachine?.name ?? "Machine")
  }

  /// No project is an ordinary choice, including its favorite state.
  func projectPicker(_ controller: SessionController) -> some View {
    let selected = controller.project
    let isNoProject = selected.isRunTargetPlaceholder || selected.isScratch
    let groups = pickerGroups(on: selected.serverId)
    let selectedGroup = isNoProject ? nil : groups.first { $0.contains(selected) }
    let chipText = isNoProject ? "No project" : (selectedGroup?.name ?? selected.name)
    let selection = Binding<ProjectPickerTarget>(
      get: { isNoProject ? .noProject : .project(selectedGroup?.id ?? selected.id.uuidString) },
      set: { target in
        switch target {
        case .noProject: selectNoProject(controller)
        case let .project(id):
          if let group = groups.first(where: { $0.id == id }) { selectTargetGroup(group, controller: controller) }
        }
      }
    )
    let favorites = Binding<[ProjectPickerTarget]>(
      get: { favoriteProjectIDs.map { $0 == Self.noProjectFavoriteID ? .noProject : .project($0) } },
      set: { targets in
        favoriteProjectIDs = targets.map {
          switch $0 {
          case .noProject: Self.noProjectFavoriteID
          case let .project(id): id
          }
        }
      }
    )
    return RunPickerMenu(
      chipText: chipText, chipSymbol: isNoProject ? Self.noProjectSymbol : EntitySystemSymbol.project
    ) {
      Autocomplete.Picker("Projects", selection: selection) {
        Autocomplete.Choice(
          Self.noProjectTitle, value: ProjectPickerTarget.noProject, systemImage: Self.noProjectSymbol)
        for group in groups {
          Autocomplete.Choice(
            group.name, value: ProjectPickerTarget.project(group.id), systemImage: EntitySystemSymbol.project)
        }
      }
      .favorites(favorites)
      .labelsHidden()
      Autocomplete.Section(id: "actions") {
        Autocomplete.Action("New Project…", systemImage: "folder.badge.plus") {
          newProjectTarget = NewProjectTarget(serverId: selected.serverId)
        }
        .help("Add a project")
      }
    }
    .autocompleteSearchLabel("Search projects")
    .autocompleteEmptyMessage("No matching projects")
    .onHover { trackHover(.project, $0) }
    .help("Choose which project this chat works in")
    .accessibilityLabel("Project")
    .accessibilityValue(chipText)
  }

  /// The outline folder: a chat with no repository behind it.
  static let noProjectSymbol = EntitySystemSymbol.projectList
  private static let noProjectTitle = "No project"
  /// Project group IDs use repo| or project| prefixes; this key cannot
  /// collide with a repository and is shared across all machines.
  private static let noProjectFavoriteID = "no-project"

  /// "Project directory" vs "New worktree" for where the chat (and its
  /// workspace) runs. Only rendered for git projects; the worktree itself
  /// is created on the first send.
  func runLocationPicker(_ controller: SessionController) -> some View {
    let current = RunLocationOption.all.first { $0.newWorktree == controller.wantsNewWorktree } ?? .projectDirectory
    let selection = Binding(
      get: { controller.wantsNewWorktree },
      set: { selectRunLocation(newWorktree: $0, controller: controller) }
    )
    return RunPickerMenu(chipText: current.title, chipSymbol: current.symbol) {
      Autocomplete.Picker("Run location", selection: selection, options: RunLocationOption.all) { option in
        Autocomplete.Choice(option.title, value: option.newWorktree, systemImage: option.symbol)
      }
      .labelsHidden()
      Autocomplete.Section(id: "actions") {
        Autocomplete.Action("Manage Project…", systemImage: "gearshape") {
          managedProject = liveProject(for: controller)
        }
        .help("Manage this project")
      }
    }
    .autocompleteSearchLabel("Search run locations")
    .autocompleteEmptyMessage("No matching run locations")
    .onHover { trackHover(.location, $0) }
    .help("Where this chat's commands run")
    .accessibilityLabel("Run location")
    .accessibilityValue(current.title)
  }

  /// Re-points the draft at another machine, keeping the current run
  /// target when that machine can honor it: the same linked project (via
  /// its checkout there) with the same run location — a worktree only if
  /// that checkout is a git repository — or "No project", which every
  /// machine can do. Only when the machine lacks the project does the
  /// draft fall back to that machine's last-used project and location.
  func selectTargetMachine(_ machine: CodevisorMachine, controller: SessionController) {
    let current = controller.project
    guard machine.id != current.serverId else { return }
    environment.composerDefaults.rememberNewWorkspaceServer(serverId: machine.id)
    if let linked = environment.projectList.fleetProjectGroup(containing: current)?
      .member(on: machine.id)
    {
      selectTargetProject(
        linked,
        controller: controller,
        wantsWorktree: controller.wantsNewWorktree && linked.isGitRepository
      )
      return
    }
    let scoped = pickerProjects.filter { $0.serverId == machine.id }
    let remembered = environment.composerDefaults.lastProjectId(forServer: machine.id)
    let isNoProject = current.isRunTargetPlaceholder || current.isScratch
    guard !isNoProject, let project = scoped.first(where: { $0.id == remembered })
    else {
      // "No project" is a stable run-target state: keep the draft and
      // composer in place rather than guessing a project or opening a
      // dialog.
      selectedProjectId = nil
      Task {
        await controller.retarget(
          to: .runTargetPlaceholder(serverId: machine.id),
          serverClient: environment.machines.client(for: machine.id)
        )
        await environment.refreshHarnessLifecycle(for: machine.id)
      }
      return
    }
    selectTargetProject(project, controller: controller)
  }

  /// Picking a linked project uses its checkout on the draft's machine
  /// (the picker only lists such projects); the recency fallback covers a
  /// stale menu.
  func selectTargetGroup(_ group: ProjectGroup, controller: SessionController) {
    let project =
      group.member(on: controller.project.serverId)
      ?? environment.projectList.mostRecentlyUsedMember(of: group)
    selectTargetProject(project, controller: controller)
  }

  /// Untie the draft from any project: its first send will run in a
  /// fresh single-use folder on the current machine.
  func selectNoProject(_ controller: SessionController) {
    // Already there (a retained scratch-backed draft counts): nothing to
    // re-point.
    guard !controller.project.isRunTargetPlaceholder, !controller.project.isScratch else { return }
    let serverId = controller.project.serverId
    selectedProjectId = nil
    environment.composerDefaults.rememberNewWorkspaceProject(
      serverId: serverId,
      projectId: Project.runTargetPlaceholderID
    )
    Task {
      await controller.selectProject(.runTargetPlaceholder(serverId: serverId))
    }
  }

  /// A picked project carries the machine's remembered worktree preference
  /// (worktrees only make sense for git projects) unless the caller pins
  /// the run location — a machine switch keeping the draft's own choice.
  func selectTargetProject(
    _ project: Project,
    controller: SessionController,
    wantsWorktree: Bool? = nil
  ) {
    selectedProjectId = project.id
    environment.composerDefaults.rememberNewWorkspaceProject(
      serverId: project.serverId,
      projectId: project.id
    )
    let prefersWorktree =
      wantsWorktree
      ?? (project.isGitRepository
        && environment.composerDefaults.prefersWorktreeForNewWorkspaces(
          forServer: project.serverId
        ))
    Task {
      if project.serverId != controller.project.serverId {
        // Another machine's project: the draft re-points there in
        // place — client, catalog and all. The eventual route carries
        // this machine id; no app-wide selection changes.
        await controller.retarget(
          to: project,
          serverClient: environment.machines.client(for: project.serverId)
        )
        await environment.refreshHarnessLifecycle(for: project.serverId)
      } else {
        await controller.selectProject(project)
      }
      guard controller.project.serverId == project.serverId,
        controller.project.id == project.id
      else { return }
      controller.wantsNewWorktree = prefersWorktree
    }
    // Re-probe git capability on the picked project's machine so the
    // run-location picker appears/disappears with fresh data.
    Task {
      await environment.projectList.refreshFromServer(
        serverId: project.serverId,
        client: environment.machines.client(for: project.serverId)
      )
    }
  }

  /// Archiving the draft's project leaves the draft with no project rather
  /// than guessing another one.
  func archiveManagedProject(_ project: Project, controller: SessionController?) {
    environment.projectList.archive(project)
    guard let controller else { return }
    selectNoProject(controller)
  }

  private func selectRunLocation(newWorktree: Bool, controller: SessionController) {
    environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
      serverId: controller.project.serverId,
      createsWorktree: newWorktree
    )
    controller.wantsNewWorktree = newWorktree
  }
}

/// One row of the run-location picker.
private struct RunLocationOption: Identifiable {
  let id: NewChatView.RunLocationPickerTarget
  let title: String
  let symbol: String
  let newWorktree: Bool

  static let projectDirectory = RunLocationOption(
    id: .projectDirectory, title: "Project directory", symbol: "folder.fill", newWorktree: false
  )
  static let newWorktree = RunLocationOption(
    id: .newWorktree, title: "New worktree", symbol: "arrow.triangle.branch", newWorktree: true
  )
  static let all = [projectDirectory, newWorktree]
}
