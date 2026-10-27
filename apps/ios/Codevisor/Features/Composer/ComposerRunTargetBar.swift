import CodevisorCore
import CodevisorUI
import SwiftUI

struct ComposerRunTargetBar: View {
  let machineName: String
  let hasOtherMachines: Bool
  let machineIcon: Image
  let machines: [CodevisorMachine]
  let selectedServerId: String
  let readyMachineIds: Set<String>
  let project: Project
  let pendingSetupGroup: ProjectGroup?
  let wantsNewWorktree: Bool
  let onMachine: (CodevisorMachine) -> Void
  let onProject: (Project) -> Void
  let onSetUpProject: (ProjectGroup) -> Void
  let onLocation: @MainActor (Bool) -> Void
  let onManageMachines: () -> Void
  let onManageProject: () -> Void
  let onProjectDeleted: (ProjectGroup) -> Void
  let sandboxes: ComposerSandboxPicks
  @State private var sandboxProfiles = SandboxProfileCatalog()

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .footnote) private var minimumMachineWidth = 88.0
  @ScaledMetric(relativeTo: .footnote) private var minimumProjectWidth = 128.0

  var body: some View {
    RunTargetPickerLayout(
      stacksVertically: dynamicTypeSize.isAccessibilitySize,
      minimumMachineWidth: minimumMachineWidth,
      minimumProjectWidth: minimumProjectWidth
    ) {
      if hasOtherMachines || !sandboxProfiles.choices.isEmpty {
        chipLabel(machineName, icon: machineIcon)
          .accessibilityHidden(true)
          .overlay {
            ComposerMachineMenu(
              machineName: machineName,
              machines: machines,
              selectedServerId: selectedServerId,
              readyMachineIds: readyMachineIds,
              sandboxChoices: sandboxProfiles.choices,
              selectedProfileId: sandboxes.selectedProfileId,
              onMachine: onMachine,
              onSandbox: sandboxes.onPick,
              onManageMachines: onManageMachines,
              onManageSandboxes: sandboxes.enabled ? sandboxes.onManage : nil
            )
          }
          .layoutValue(key: RunTargetPickerRoleKey.self, value: .machine)
        pickerDivider
      }
      ComposerProjectMenu(
        currentProject: project,
        pendingSetupGroup: pendingSetupGroup,
        onSelected: onProject,
        onSetUp: onSetUpProject,
        onProjectDeleted: onProjectDeleted
      ) {
        chipLabel(
          projectName,
          symbol: isPlaceholder ? EntitySystemSymbol.projectList : EntitySystemSymbol.project
        )
      }
      .id(project.serverId)
      .accessibilityLabel("Project")
      .accessibilityValue(projectName)
      .accessibilityIdentifier("newChat.projectPicker")
      .layoutValue(key: RunTargetPickerRoleKey.self, value: .project)
      if !isPlaceholder && pendingSetupGroup == nil && project.isGitRepository {
        pickerDivider
        Menu {
          Section {
            Button("Manage Project…", systemImage: "gearshape", action: onManageProject)
          }
          Picker(
            "Run location",
            selection: Binding(get: { wantsNewWorktree }, set: onLocation)
          ) {
            Label("Project directory", systemImage: "folder.fill").tag(false)
            Label("New worktree", systemImage: "arrow.triangle.branch").tag(true)
          }
        } label: {
          ViewThatFits(in: .horizontal) {
            chipLabel(
              wantsNewWorktree ? "Worktree" : "Project",
              symbol: locationSymbol
            )
            .fixedSize(horizontal: true, vertical: false)
            chipLabel(nil, symbol: locationSymbol)
          }
        }
        .menuIndicator(.hidden)
        .menuOrder(.fixed)
        .accessibilityLabel("Run location")
        .accessibilityValue(wantsNewWorktree ? "New worktree" : "Project directory")
        .accessibilityIdentifier("newChat.locationPicker")
        .layoutValue(key: RunTargetPickerRoleKey.self, value: .location)
      }
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 4)
    .accessibilityElement(children: .contain)
    .task(id: "\(selectedServerId)|\(sandboxes.enabled)") { await sandboxes.load(sandboxProfiles) }
  }

  private var locationSymbol: String {
    wantsNewWorktree ? "arrow.triangle.branch" : "folder.fill"
  }

  private var isPlaceholder: Bool {
    pendingSetupGroup == nil && (project.isRunTargetPlaceholder || project.isScratch)
  }

  private var projectName: String {
    if let pendingSetupGroup { return pendingSetupGroup.name }
    return isPlaceholder ? "No project" : project.name
  }

  private var pickerDivider: some View {
    Rectangle()
      .fill(.quaternary)
      .frame(minWidth: 0, idealWidth: 1, maxWidth: 1, minHeight: 0, idealHeight: 14, maxHeight: 14)
      .layoutValue(key: RunTargetPickerRoleKey.self, value: .divider)
      .accessibilityHidden(true)
  }

  private func chipLabel(_ title: String?, symbol: String) -> some View {
    chipLabel(title, icon: Image(systemName: symbol))
  }

  private func chipLabel(_ title: String?, icon: Image) -> some View {
    HStack(spacing: 4) {
      icon
        .font(.caption)
        .fixedSize()
      if let title {
        Text(title)
          .lineLimit(1)
          .truncationMode(.middle)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
  }
}
