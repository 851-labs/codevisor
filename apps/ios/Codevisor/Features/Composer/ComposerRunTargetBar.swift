import CodevisorCore
import CodevisorUI
import SwiftUI

/// Independent run-target controls share one surface and a bounded width.
struct ComposerRunTargetBar: View {
  let machineName: String?
  let machineSymbol: String
  let machines: [CodevisorMachine]
  let selectedServerId: String
  let readyMachineIds: Set<String>
  let project: Project
  let wantsNewWorktree: Bool
  let onMachine: (CodevisorMachine) -> Void
  let onProject: (Project) -> Void
  let onLocation: (Bool) -> Void
  let onManageMachines: () -> Void
  let onManageProject: () -> Void
  let onArchiveProject: (Project) -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .footnote) private var minimumMachineWidth = 88.0
  @ScaledMetric(relativeTo: .footnote) private var minimumProjectWidth = 128.0

  var body: some View {
    RunTargetPickerLayout(
      stacksVertically: dynamicTypeSize.isAccessibilitySize,
      minimumMachineWidth: minimumMachineWidth,
      minimumProjectWidth: minimumProjectWidth
    ) {
      if let machineName {
        chipLabel(machineName, symbol: machineSymbol)
          .accessibilityHidden(true)
          .overlay {
            ComposerMachineMenu(
              machineName: machineName,
              machines: machines,
              selectedServerId: selectedServerId,
              readyMachineIds: readyMachineIds,
              onMachine: onMachine,
              onManageMachines: onManageMachines
            )
          }
          .layoutValue(key: RunTargetPickerRoleKey.self, value: .machine)
        pickerDivider
      }
      ComposerProjectMenu(
        currentProject: project,
        onSelected: onProject,
        onArchiveProject: onArchiveProject
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
      if !isPlaceholder && project.isGitRepository {
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
    .font(.footnote)
    .foregroundStyle(.secondary)
    .buttonStyle(.plain)
    .padding(.horizontal, 4)
    .accessibilityElement(children: .contain)
  }

  private var locationSymbol: String {
    wantsNewWorktree ? "arrow.triangle.branch" : "folder.fill"
  }

  private var isPlaceholder: Bool {
    project.isRunTargetPlaceholder || project.isScratch
  }

  private var projectName: String {
    isPlaceholder ? "No project" : project.name
  }

  private var pickerDivider: some View {
    Rectangle()
      .fill(.quaternary)
      .frame(minWidth: 0, idealWidth: 1, maxWidth: 1, minHeight: 0, idealHeight: 14, maxHeight: 14)
      .layoutValue(key: RunTargetPickerRoleKey.self, value: .divider)
      .accessibilityHidden(true)
  }

  private func chipLabel(_ title: String?, symbol: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol)
        .font(.caption)
        .fixedSize()
      if let title {
        Text(title)
          // Stacked rows still truncate: long names must not push the
          // composer under the sheet's header while the keyboard is open.
          .lineLimit(1)
          .truncationMode(.middle)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
  }
}
