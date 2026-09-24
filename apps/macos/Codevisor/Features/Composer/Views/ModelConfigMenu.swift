import ACPKit
import CodevisorCore
import CodevisorUI
import Autocomplete
import SwiftUI

/// Separate model and parameter controls shared by draft and connected
/// composers. Both use Autocomplete's searchable picker presentation;
/// parameters are grouped by option, each with its own current value.
struct ModelConfigMenu: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.openSettings) private var openSettings
  @Bindable var controller: SessionController

  @ClientPreference("composer.favoriteModels", default: [])
  private var favoriteModelIDs: [ModelPickerFavorite]
  @State private var isPresented = false
  @State private var isParametersPresented = false
  /// The pick most recently handed to the controller. The chip shows it
  /// (with a spinner) until the task that applied it finishes; a newer
  /// pick supersedes an older in-flight one instead of waiting on it.
  @State private var pendingSelection: PendingSelection?
  @State private var selectionRevision: UInt64 = 0

  private struct PendingSelection {
    let groupId: String
    let modelValue: String
    let modelName: String
  }

  var body: some View {
    // A background revalidation must not replace an already-usable model
    // control (or dismiss its open popover) with a spinner. Reserve the
    // loading placeholder only for a true cache miss.
    if controller.isLoadingModelMenu, modelGroups.isEmpty {
      ProgressView()
        .controlSize(.small)
        .frame(minWidth: 96)
        .help("Loading model settings")
        .accessibilityLabel("Loading model settings")
    } else if !modelGroups.isEmpty || !signInRequiredHarnesses.isEmpty || !settingsOptions.isEmpty {
      HStack(spacing: 10) {
        if !modelGroups.isEmpty || !signInRequiredHarnesses.isEmpty {
          modelButton
        }
        if !settingsOptions.isEmpty {
          parametersMenu
        }
      }
    }
  }
}

private extension ModelConfigMenu {
  private var modelButton: some View {
    Autocomplete.Menu(isPresented: $isPresented) {
      for group in modelGroups {
        Autocomplete.Picker(group.name, id: group.id, selection: modelSelection, options: group.modelOption.options) {
          model in
          Autocomplete.Choice(model.name, value: ModelPickerFavorite(model: model, group: group))
            .searchTerms([model.value, group.name])
        }
        .favorites($favoriteModelIDs)
      }
      // An enabled harness whose account needs attention has no model list,
      // so without these rows it would vanish from the picker as if it were
      // turned off.
      for harness in signInRequiredHarnesses {
        Autocomplete.Section(harness.name, id: "sign-in:\(harness.id)") {
          Autocomplete.Action(
            "Sign in to use \(harness.name)…",
            id: "sign-in:\(harness.id)",
            systemImage: "person.crop.circle.badge.exclamationmark"
          ) { showHarnessAccounts(harness.id) }
          .searchTerms([harness.name, harness.id])
          .help("\(harness.name)'s account on this machine needs to be signed in again")
        }
      }
      Autocomplete.Footer(id: "actions") {
        Autocomplete.Action("Manage Harnesses…", action: showHarnessSettings)
          .help("Open Harness Settings")
      }
    } label: {
      modelChipLabel
    }
    .autocompleteSearchLabel("Search models")
    .autocompleteEmptyMessage("No matching models")
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .fixedSize(horizontal: false, vertical: true)
    .help("Choose model")
    .accessibilityLabel("Model")
    .accessibilityValue(controller.modelOption?.currentName ?? "No model selected")
  }

  private var modelSelection: Binding<ModelPickerFavorite> {
    Binding(
      get: {
        if let pendingSelection {
          return ModelPickerFavorite(
            harnessID: pendingSelection.groupId,
            modelValue: pendingSelection.modelValue
          )
        }
        return ModelPickerFavorite(
          harnessID: controller.activeHarnessId ?? "active",
          modelValue: controller.modelOption?.currentValue ?? ""
        )
      },
      set: { favorite in
        guard let group = modelGroups.first(where: { $0.id == favorite.harnessID }),
          let model = group.modelOption.options.first(where: { $0.value == favorite.modelValue }),
          !isCurrent(model, in: group)
        else { return }
        choose(model, in: group)
      }
    )
  }

  private var parametersMenu: some View {
    Autocomplete.Menu(isPresented: $isParametersPresented) {
      for option in settingsOptions {
        Autocomplete.Picker(option.name, id: option.id, selection: parameterSelection(option), options: option.options)
        { value in
          Autocomplete.Choice(value.name, value: value.value).searchTerms([value.value])
        }
      }
    } label: {
      parameterChipLabel
    }
    .autocompleteSearchLabel("Search model parameters")
    .autocompleteEmptyMessage("No matching parameters")
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .fixedSize()
    .help("Model parameters")
    .accessibilityLabel("Model parameters")
    .accessibilityValue(parameterAccessibilityValue)
  }

  private func parameterSelection(_ option: SessionConfigOption) -> Binding<String> {
    Binding(
      get: { option.currentValue },
      set: { value in
        guard option.currentValue != value else { return }
        Task { await controller.setConfigOption(option.id, value) }
      }
    )
  }

  private func showHarnessSettings() {
    isPresented = false
    SettingsRouter.shared.showHarnesses(machineId: controller.project.serverId)
    openSettings()
  }

  private func showHarnessAccounts(_ harnessId: String) {
    isPresented = false
    SettingsRouter.shared.showHarnessAccounts(
      machineId: controller.project.serverId,
      harnessId: harnessId
    )
    openSettings()
  }

  /// Enabled harnesses the server reports as blocked on sign-in. Only a new
  /// chat can switch harness, so only its picker offers them.
  private var signInRequiredHarnesses: [ServerHarness] {
    guard controller.canChooseHarness else { return [] }
    let usable = Set(modelGroups.map(\.id))
    return environment.configCache
      .signInRequired(forServer: controller.project.serverId)
      .filter { !usable.contains($0.id) }
  }

  private var modelGroups: [ModelMenuGroup] {
    let serverId = controller.project.serverId
    if controller.canChooseHarness {
      // Derived straight from the per-machine cache: the list is
      // server-correct by construction and re-renders on any store,
      // with no controller-held copy to go stale across a machine
      // switch.
      return environment.configCache.capabilities(forServer: serverId).compactMap {
        capability in
        let harness = capability.harness
        let options: [SessionConfigOption]
        if harness.id == controller.activeHarnessId {
          options = controller.configOptions
        } else if !capability.configOptions.isEmpty {
          options = capability.configOptions
        } else {
          options = environment.configCache.options(
            forHarness: harness.id,
            onServer: serverId
          )
        }
        guard
          let model = options.first(where: {
            $0.category == SessionConfigOption.Category.model && !$0.options.isEmpty
          })
        else { return nil }
        return ModelMenuGroup(
          id: harness.id,
          name: harness.name,
          symbolName: harness.symbolName,
          modelOption: model
        )
      }
    }
    guard let model = controller.modelOption else { return [] }
    let harness =
      controller.harnesses.first { $0.id == controller.activeHarnessId }
      ?? controller.selectedHarness
    return [
      ModelMenuGroup(
        id: controller.activeHarnessId ?? "active",
        name: harness?.name ?? "Model",
        symbolName: harness?.symbolName ?? "sparkle",
        modelOption: model
      )
    ]
  }

  private func isCurrent(
    _ model: SessionConfigSelectOption,
    in group: ModelMenuGroup
  ) -> Bool {
    if let pendingSelection {
      return pendingSelection.groupId == group.id && pendingSelection.modelValue == model.value
    }
    return controller.activeHarnessId == group.id
      && group.modelOption.currentValue == model.value
  }

  private func choose(_ model: SessionConfigSelectOption, in group: ModelMenuGroup) {
    selectionRevision &+= 1
    let revision = selectionRevision
    pendingSelection = PendingSelection(
      groupId: group.id,
      modelValue: model.value,
      modelName: model.name
    )
    isPresented = false
    Task {
      if controller.activeHarnessId != group.id, controller.canChooseHarness {
        await controller.selectHarness(group.id)
      }
      if let liveModel = controller.modelOption {
        await controller.setConfigOption(liveModel.id, model.value)
      }
      // Only the newest pick clears the pending state: an older one
      // finishing late must not flash its outcome over a newer choice.
      guard revision == selectionRevision else { return }
      pendingSelection = nil
    }
  }

  /// The parameter list can change with the model, so it reads as
  /// refreshing while a model pick (here or a machine switch) is settling.
  private var isRefreshingParameters: Bool {
    pendingSelection != nil || controller.isResolvingModelConfiguration
  }

  private var settingsOptions: [SessionConfigOption] {
    ModelParameterMenu.options(from: controller.configOptions)
  }

  private var parameterAccessibilityValue: String {
    let summary = summarizedSettingsOptions.map { "\($0.name), \($0.currentName)" }
      .joined(separator: ", ")
    let value = summary.isEmpty ? "Default" : summary
    return isRefreshingParameters ? "\(value), updating" : value
  }

  private var summarizedSettingsOptions: [SessionConfigOption] {
    ModelParameterMenu.summarized(settingsOptions)
  }

  private var parameterChipSummary: String {
    let summary = summarizedSettingsOptions.map(\.currentName).joined(separator: " · ")
    return summary.isEmpty ? "Options" : summary
  }

  private var modelChipLabel: some View {
    ModelPickerChipLabel(
      group: pendingModelGroup ?? activeModelGroup,
      modelName: pendingSelection?.modelName ?? controller.modelOption?.currentName,
      isLoading: pendingSelection != nil
    )
  }

  private var pendingModelGroup: ModelMenuGroup? {
    guard let pendingSelection else { return nil }
    return modelGroups.first { $0.id == pendingSelection.groupId }
  }

  private var activeModelGroup: ModelMenuGroup? {
    guard let activeHarnessId = controller.activeHarnessId else { return modelGroups.first }
    return modelGroups.first { $0.id == activeHarnessId } ?? modelGroups.first
  }

  private var parameterChipLabel: some View {
    HStack(spacing: 5) {
      Text(parameterChipSummary)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if isRefreshingParameters {
        ProgressView()
          .controlSize(.mini)
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
  }
}
