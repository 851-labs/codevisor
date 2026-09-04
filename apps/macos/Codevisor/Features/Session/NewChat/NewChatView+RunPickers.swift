import CodevisorCore
import CodevisorUI
import SwiftUI

extension NewChatView {
  enum RunPicker {
    case machine, project, location
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
    let selectedServerId = controller.project.serverId
    let selectedMachine = environment.machines.machine(for: selectedServerId)
    return Menu {
      // Toggle for the native selected checkmark; MenuSymbolIcon
      // because AppKit menus drop plain SF Symbol images.
      ForEach(environment.machines.allMachines) { machine in
        Toggle(
          isOn: Binding(
            get: { machine.id == selectedServerId },
            set: { isOn in
              guard isOn else { return }
              selectTargetMachine(machine, controller: controller)
            }
          )
        ) {
          Label {
            Text(machine.name)
          } icon: {
            MenuSymbolIcon(systemName: EntitySystemSymbol.machine(machine))
          }
        }
      }
      Divider()
      Button {
        SettingsRouter.shared.showMachines()
        openSettings()
      } label: {
        Label {
          Text("Manage Machines…")
        } icon: {
          MenuSymbolIcon(systemName: "gearshape")
        }
      }
    } label: {
      PickerChip(text: selectedMachine?.name ?? "Machine") {
        Image(
          systemName: selectedMachine.map(EntitySystemSymbol.machine)
            ?? EntitySystemSymbol.machine(.local)
        )
        .font(.system(size: 12))
      }
    }
    .menuStyle(.button)
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .menuIndicator(.hidden)
    .fixedSize()
    .onHover { trackHover(.machine, $0) }
    .help("Choose which machine this chat runs on")
    .accessibilityLabel("Machine")
    .accessibilityValue(selectedMachine?.name ?? "Machine")
  }

  /// Choose the project the chat (and the workspace created around it on
  /// first send) will work in. "No project" is a first-class choice — the
  /// chat gets a single-use folder — and the default when nothing is
  /// remembered, so a machine with no projects yet is not a dead end.
  func projectPicker(_ controller: SessionController) -> some View {
    let selected = controller.project
    // A draft retained after a failed first send keeps the scratch folder
    // it was allocated (the retry reuses it); to the user that is still
    // "No project", never the folder's generated name.
    let isNoProject = selected.isRunTargetPlaceholder || selected.isScratch
    let groups = pickerGroups(on: selected.serverId)
    let selectedGroup = isNoProject ? nil : groups.first { $0.contains(selected) }
    let chipText = isNoProject ? "No project" : (selectedGroup?.name ?? selected.name)
    return Menu {
      // Toggle for the native selected checkmark; MenuSymbolIcon
      // because AppKit menus drop plain SF Symbol images.
      Toggle(
        isOn: Binding(
          get: { isNoProject },
          set: { isOn in
            guard isOn else { return }
            selectNoProject(controller)
          }
        )
      ) {
        Label {
          Text("No project")
        } icon: {
          MenuSymbolIcon(systemName: Self.noProjectSymbol)
        }
      }
      if !groups.isEmpty {
        Divider()
      }
      ForEach(groups) { group in
        Toggle(
          isOn: Binding(
            get: { group.contains(selected) },
            set: { isOn in
              guard isOn else { return }
              selectTargetGroup(group, controller: controller)
            }
          )
        ) {
          Label {
            Text(group.name)
          } icon: {
            MenuSymbolIcon(systemName: EntitySystemSymbol.project)
          }
        }
      }
      Divider()
      Button {
        newProjectTarget = NewProjectTarget(serverId: selected.serverId)
      } label: {
        Label {
          Text("New Project…")
        } icon: {
          MenuSymbolIcon(systemName: "folder.badge.plus")
        }
      }
    } label: {
      PickerChip(text: chipText) {
        Image(
          systemName: isNoProject
            ? Self.noProjectSymbol : EntitySystemSymbol.project
        )
        .font(.system(size: 12))
      }
    }
    .menuStyle(.button)
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .menuIndicator(.hidden)
    .fixedSize()
    .onHover { trackHover(.project, $0) }
    .help("Choose which project this chat works in")
    .accessibilityLabel("Project")
    .accessibilityValue(chipText)
  }

  /// The outline folder: a chat with no repository behind it.
  static let noProjectSymbol = EntitySystemSymbol.projectList

  /// "Project directory" vs "New worktree" for where the chat (and its
  /// workspace) runs. Only rendered for git projects; the worktree itself
  /// is created on the first send.
  func runLocationPicker(_ controller: SessionController) -> some View {
    let newWorktree = controller.wantsNewWorktree
    return Menu {
      Toggle(
        isOn: Binding(
          get: { !newWorktree },
          set: { isOn in
            guard isOn else { return }
            selectRunLocation(newWorktree: false, controller: controller)
          }
        )
      ) {
        Label {
          Text("Project directory")
        } icon: {
          MenuSymbolIcon(systemName: "folder.fill")
        }
      }
      Toggle(
        isOn: Binding(
          get: { newWorktree },
          set: { isOn in
            guard isOn else { return }
            selectRunLocation(newWorktree: true, controller: controller)
          }
        )
      ) {
        Label {
          Text("New worktree")
        } icon: {
          MenuSymbolIcon(systemName: "arrow.triangle.branch")
        }
      }
      Divider()
      Button {
        managedProject = liveProject(for: controller)
      } label: {
        Label {
          Text("Manage Project…")
        } icon: {
          MenuSymbolIcon(systemName: "gearshape")
        }
      }
    } label: {
      PickerChip(text: newWorktree ? "New worktree" : "Project directory") {
        Image(systemName: newWorktree ? "arrow.triangle.branch" : "folder.fill")
          .font(.system(size: 12))
      }
    }
    .menuStyle(.button)
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .menuIndicator(.hidden)
    .fixedSize()
    .onHover { trackHover(.location, $0) }
    .help("Where this chat's commands run")
    .accessibilityLabel("Run location")
    .accessibilityValue(newWorktree ? "New worktree" : "Project directory")
  }

  /// Re-points the draft at another machine: the same linked project when
  /// that machine has a checkout of it, else the machine's remembered
  /// project, else no project.
  func selectTargetMachine(_ machine: CodevisorMachine, controller: SessionController) {
    let current = controller.project
    guard machine.id != current.serverId else { return }
    environment.composerDefaults.rememberNewWorkspaceServer(serverId: machine.id)
    let linked =
      current.isRunTargetPlaceholder
      ? nil
      : environment.projectList.fleetProjectGroup(containing: current)?.member(on: machine.id)
    let scoped = pickerProjects.filter { $0.serverId == machine.id }
    let remembered = environment.composerDefaults.lastProjectId(forServer: machine.id)
    guard let project = linked ?? scoped.first(where: { $0.id == remembered })
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
  /// (worktrees only make sense for git projects).
  func selectTargetProject(_ project: Project, controller: SessionController) {
    selectedProjectId = project.id
    environment.composerDefaults.rememberNewWorkspaceProject(
      serverId: project.serverId,
      projectId: project.id
    )
    let prefersWorktree =
      project.isGitRepository
      && environment.composerDefaults.prefersWorktreeForNewWorkspaces(
        forServer: project.serverId
      )
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
