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
  }

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

  var showsRunPickers: Bool { paneDraftId == nil }

  private var pickerProjects: [Project] {
    environment.projectList.fleetActiveProjectsByWorkspaceRecency(
      environment.workspaces.loadAll()
    )
    .filter { !$0.isScratch }
  }

  private var pickerGroups: [ProjectGroup] {
    environment.projectList.fleetActiveProjectGroupsByWorkspaceRecency(
      environment.workspaces.loadAll()
    )
  }

  var showsMachinePicker: Bool { environment.machines.allMachines.count > 1 }

  func liveProject(for controller: SessionController) -> Project {
    environment.projectList.projects.first {
      $0.serverId == controller.project.serverId && $0.id == controller.project.id
    } ?? controller.project
  }

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
      chipSymbol: (selectedMachine?.icon ?? .fallback).systemImage
    ) {
      Autocomplete.Picker("Machines", selection: selection, options: machines) { machine in
        Autocomplete.Choice(machine.name, value: machine.id) {
          if case .waiting = environment.machines.availability(for: machine.id) {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: machine.icon.systemImage)
          }
        } label: {
          Text(machine.name)
        }
        .disabled(environment.machines.availability(for: machine.id) != .ready)
      }
      .favorites($favoriteMachineIDs)
      .labelsHidden()
      Autocomplete.Footer(id: "actions") {
        Autocomplete.Action("Manage Machines…", systemImage: "gearshape.fill") {
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

  func projectPicker(_ controller: SessionController) -> some View {
    let selected = controller.project
    let pending = selected.isRunTargetPlaceholder ? pendingSetupGroup : nil
    let isNoProject = pending == nil && (selected.isRunTargetPlaceholder || selected.isScratch)
    let groups = pickerGroups
    let selectedGroup = pending ?? (isNoProject ? nil : groups.first { $0.contains(selected) })
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
      Autocomplete.Footer(id: "actions") {
        Autocomplete.Action("Manage projects…", systemImage: "gearshape.fill") {
          SettingsRouter.shared.showProjects(machineId: selected.serverId)
          openSettings()
        }
        .help("Open Project Settings")
      }
    }
    .autocompleteSearchLabel("Search projects")
    .autocompleteEmptyMessage("No matching projects")
    .onHover { trackHover(.project, $0) }
    .help("Choose which project this chat works in")
    .accessibilityLabel("Project")
    .accessibilityValue(chipText)
  }

  static let noProjectSymbol = EntitySystemSymbol.projectList
  private static let noProjectTitle = "No project"
  private static let noProjectFavoriteID = "no-project"

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
      Autocomplete.Footer(id: "actions") {
        Autocomplete.Action("Manage Project…", systemImage: "gearshape.fill") {
          SettingsRouter.shared.showProject(liveProject(for: controller))
          openSettings()
        }
        .help("Open this project's settings")
      }
    }
    .autocompleteSearchLabel("Search run locations")
    .autocompleteEmptyMessage("No matching run locations")
    .onHover { trackHover(.location, $0) }
    .help("Where this chat's commands run")
    .accessibilityLabel("Run location")
    .accessibilityValue(current.title)
  }

  func selectTargetMachine(_ machine: CodevisorMachine, controller: SessionController) {
    let current = controller.project
    guard machine.id != current.serverId else { return }
    environment.composerDefaults.rememberNewWorkspaceServer(serverId: machine.id)
    let currentGroup =
      current.isRunTargetPlaceholder
      ? pendingSetupGroup : environment.projectList.fleetProjectGroup(containing: current)
    if let linked = currentGroup?.member(on: machine.id) {
      pendingSetupGroupID = nil
      selectTargetProject(
        linked,
        controller: controller,
        wantsWorktree: controller.wantsNewWorktree && linked.isGitRepository
      )
      return
    }
    if let currentGroup {
      pendingSetupGroupID = currentGroup.id
      selectedProjectId = nil
      Task {
        await controller.retarget(
          to: .runTargetPlaceholder(serverId: machine.id),
          serverClient: environment.machines.client(for: machine.id)
        )
      }
      return
    }
    pendingSetupGroupID = nil
    let scoped = pickerProjects.filter { $0.serverId == machine.id }
    let remembered = environment.composerDefaults.lastProjectId(forServer: machine.id)
    let isNoProject = current.isRunTargetPlaceholder || current.isScratch
    guard !isNoProject, let project = scoped.first(where: { $0.id == remembered })
    else {
      selectedProjectId = nil
      Task {
        await controller.retarget(
          to: .runTargetPlaceholder(serverId: machine.id),
          serverClient: environment.machines.client(for: machine.id)
        )
      }
      return
    }
    selectTargetProject(project, controller: controller)
  }

  func selectTargetGroup(_ group: ProjectGroup, controller: SessionController) {
    if let project = group.member(on: controller.project.serverId) {
      selectTargetProject(project, controller: controller)
      return
    }
    let serverId = controller.project.serverId
    pendingSetupGroupID = group.id
    selectedProjectId = nil
    guard !controller.project.isRunTargetPlaceholder else { return }
    Task {
      await controller.selectProject(.runTargetPlaceholder(serverId: serverId))
    }
  }

  func selectNoProject(_ controller: SessionController) {
    pendingSetupGroupID = nil
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

  func selectTargetProject(
    _ project: Project,
    controller: SessionController,
    wantsWorktree: Bool? = nil
  ) {
    pendingSetupGroupID = nil
    selectedProjectId = project.id
    environment.composerDefaults.rememberNewWorkspaceProject(
      serverId: project.serverId,
      projectId: project.id
    )
    let prefersWorktree = wantsWorktree ?? environment.prefersNewWorktree(for: project)
    Task {
      if project.serverId != controller.project.serverId {
        await controller.retarget(
          to: project,
          serverClient: environment.machines.client(for: project.serverId)
        )
      } else {
        await controller.selectProject(project)
      }
      guard controller.project.serverId == project.serverId,
        controller.project.id == project.id
      else { return }
      controller.wantsNewWorktree = prefersWorktree
    }
    Task {
      await environment.projectList.refreshFromServer(
        serverId: project.serverId,
        client: environment.machines.client(for: project.serverId)
      )
    }
  }

  var selectedDraftProjectIsDeleted: Bool {
    guard showsRunPickers, let controller else { return false }
    return environment.projectList.isProjectDeleted(
      id: controller.project.id,
      serverId: controller.project.serverId
    )
  }

  private func selectRunLocation(newWorktree: Bool, controller: SessionController) {
    environment.rememberRunLocation(newWorktree: newWorktree, for: controller.project)
    controller.wantsNewWorktree = newWorktree
  }
}

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
