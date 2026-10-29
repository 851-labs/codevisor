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

  enum MachinePickerTarget: Hashable {
    case machine(CodevisorMachine.ID)
    case sandbox(String)

    private static let sandboxFavoritePrefix = "sandbox:"

    init(favoriteID: String) {
      if favoriteID.hasPrefix(Self.sandboxFavoritePrefix) {
        self = .sandbox(String(favoriteID.dropFirst(Self.sandboxFavoritePrefix.count)))
      } else {
        self = .machine(favoriteID)
      }
    }

    var favoriteID: String {
      switch self {
      case let .machine(id): id
      case let .sandbox(profileId): Self.sandboxFavoritePrefix + profileId
      }
    }
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

  var showsMachinePicker: Bool {
    environment.machines.chatMachines.count > 1 || !sandboxChoices.isEmpty
  }

  var sandboxChoices: [SandboxProfileChoice] {
    environment.machines.sandboxProfiles.choices(for: composerServerId)
  }

  func liveProject(for controller: SessionController) -> Project {
    environment.projectList.projects.first {
      $0.serverId == controller.project.serverId && $0.id == controller.project.id
    } ?? controller.project
  }

  func machinePicker(_ controller: SessionController) -> some View {
    let machines = environment.machines.chatMachines
    let selectedMachine = environment.machines.machine(for: controller.project.serverId)
    let sandbox = controller.sandboxTarget
    let selection = machineSelection(controller)
    let chipText = sandbox?.profileName ?? selectedMachine?.name ?? "Machine"
    return RunPickerMenu(
      chipText: chipText,
      chipIcon: sandbox.map { CodevisorSymbol.sandboxVendor($0.vendorId) }
        ?? Image(systemName: (selectedMachine?.icon ?? .fallback).systemImage),
      isBusy: controller.sandboxTargetAvailability == .checking
    ) {
      Autocomplete.Picker("Machines", selection: selection) {
        for machine in machines {
          Autocomplete.Choice(machine.name, value: MachinePickerTarget.machine(machine.id)) {
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
      }
      .favorites(machineFavorites)
      .labelsHidden()
      if !sandboxChoices.isEmpty {
        Autocomplete.Picker("Sandboxes", selection: selection) {
          for choice in controller.presentedSandboxChoices(sandboxChoices) {
            sandboxChoice(choice)
          }
        }
        .favorites(machineFavorites)
        .labelsHidden()
      }
      machinePickerFooter
    }
    .autocompleteSearchLabel("Search machines")
    .autocompleteEmptyMessage("No matching machines")
    .onHover { trackHover(.machine, $0) }
    .help("Choose which machine this chat runs on")
    .accessibilityLabel("Machine")
    .accessibilityValue(chipText)
  }

  @ViewBuilder
  func sandboxUnavailableNotice(_ controller: SessionController) -> some View {
    if showsRunPickers, let message = controller.sandboxUnavailableMessage {
      ComposerNoticeRail(
        message,
        kind: .warning,
        systemImage: "shippingbox",
        actionTitle: "Manage Sandboxes…",
        action: {
          SettingsRouter.shared.showSandboxes()
          openSettings()
        }
      )
    }
  }

  private var machinePickerFooter: Autocomplete.Footer {
    Autocomplete.Footer(id: "actions") {
      Autocomplete.Action("Manage Machines…", systemImage: "gearshape.fill") {
        SettingsRouter.shared.showMachines()
        openSettings()
      }
      .help("Open Machine Settings")
      Autocomplete.Action("Manage Sandboxes…", systemImage: "shippingbox.fill") {
        SettingsRouter.shared.showSandboxes()
        openSettings()
      }
      .help("Open Sandbox Settings")
    }
  }

  private func sandboxChoice(_ choice: SandboxProfileChoice) -> Autocomplete.Choice<MachinePickerTarget> {
    Autocomplete.Choice(choice.target.profileName, value: MachinePickerTarget.sandbox(choice.id)) {
      CodevisorSymbol.sandboxVendor(choice.target.vendorId)
    } label: {
      SandboxChoiceLabel(choice: choice)
    }
    .help(sandboxChoiceHelp(choice))
  }

  private func sandboxChoiceHelp(_ choice: SandboxProfileChoice) -> String {
    switch choice.availability {
    case .checking: "Checking whether \(choice.target.profileName) can start"
    case .available: "Start a new sandbox from this profile"
    case let .unavailable(reason): reason
    }
  }

  private func machineSelection(_ controller: SessionController) -> Binding<MachinePickerTarget> {
    Binding(
      get: { controller.sandboxTarget.map { .sandbox($0.profileId) } ?? .machine(controller.project.serverId) },
      set: { selectMachineTarget($0, controller: controller) }
    )
  }

  private var machineFavorites: Binding<[MachinePickerTarget]> {
    Binding(
      get: { favoriteMachineIDs.map(MachinePickerTarget.init(favoriteID:)) },
      set: { favoriteMachineIDs = $0.map(\.favoriteID) }
    )
  }

  private func selectMachineTarget(_ target: MachinePickerTarget, controller: SessionController) {
    switch target {
    case let .machine(id):
      controller.sandboxTarget = nil
      guard let machine = environment.machines.machine(for: id) else { return }
      selectTargetMachine(machine, controller: controller)
    case let .sandbox(profileId):
      guard let choice = sandboxChoices.first(where: { $0.id == profileId }) else { return }
      controller.sandboxTarget = choice.target
      relocateWhenSandboxIsReady(controller)
    }
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
      chipText: chipText, chipIcon: Image(systemName: isNoProject ? Self.noProjectSymbol : EntitySystemSymbol.project)
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

  func showsRunLocationPicker(_ controller: SessionController) -> Bool {
    guard controller.sandboxTarget == nil else { return false }
    return liveProject(for: controller).isGitRepository || pendingCloneGroup != nil
  }

  func runLocationPicker(_ controller: SessionController) -> some View {
    let current = RunLocationOption.all.first { $0.newWorktree == controller.wantsNewWorktree } ?? .projectDirectory
    let selection = Binding(
      get: { controller.wantsNewWorktree },
      set: { selectRunLocation(newWorktree: $0, controller: controller) }
    )
    return RunPickerMenu(
      chipText: current.title, chipIcon: Image(systemName: current.symbol), isPresented: $isRunLocationMenuPresented
    ) {
      Autocomplete.Picker("Run location", selection: selection, options: RunLocationOption.all) { option in
        Autocomplete.Choice(option.title, value: option.newWorktree, systemImage: option.symbol)
      }
      .labelsHidden()
      Autocomplete.Footer(id: "actions") {
        Autocomplete.Action("Manage Project…", systemImage: "gearshape.fill") {
          SettingsRouter.shared.showProject(pendingCloneGroup?.primary ?? liveProject(for: controller))
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
        preferCloneRunLocation(of: currentGroup, controller: controller)
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
    Task {
      await controller.selectProject(.runTargetPlaceholder(serverId: serverId))
      preferCloneRunLocation(of: group, controller: controller)
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
    if let group = pendingCloneGroup {
      environment.rememberRunLocation(newWorktree: newWorktree, for: group)
    } else {
      environment.rememberRunLocation(newWorktree: newWorktree, for: controller.project)
    }
    controller.wantsNewWorktree = newWorktree
  }

  private func preferCloneRunLocation(of group: ProjectGroup, controller: SessionController) {
    guard group.repoUrl != nil, controller.project.isRunTargetPlaceholder else { return }
    controller.wantsNewWorktree = environment.prefersNewWorktree(for: group)
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
    id: .newWorktree, title: "New worktree", symbol: CodevisorSymbol.worktreeSystemName, newWorktree: true
  )
  static let all = [projectDirectory, newWorktree]
}
