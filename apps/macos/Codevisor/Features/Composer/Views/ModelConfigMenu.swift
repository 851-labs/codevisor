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
  @State private var isSwitchingHarness = false
  @State private var pendingModelValue: String?
  @State private var pendingModelGroupId: String?

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
    } else if !modelGroups.isEmpty || !settingsOptions.isEmpty {
      HStack(spacing: 10) {
        if !modelGroups.isEmpty {
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
      Autocomplete.Section(id: "actions") {
        Autocomplete.Action("Manage Harnesses…", systemImage: "gearshape", action: showHarnessSettings)
          .help("Open Harness Settings")
      }
    } label: {
      modelChipLabel
    }
    .autocompleteSearchLabel("Search models")
    .autocompleteEmptyMessage("No matching models")
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .fixedSize(horizontal: false, vertical: true)
    .disabled(isSwitchingHarness)
    .help("Choose model")
    .accessibilityLabel("Model")
    .accessibilityValue(controller.modelOption?.currentName ?? "No model selected")
  }

  private var modelSelection: Binding<ModelPickerFavorite> {
    Binding(
      get: {
        ModelPickerFavorite(
          harnessID: pendingModelGroupId ?? controller.activeHarnessId ?? "active",
          modelValue: pendingModelValue ?? controller.modelOption?.currentValue ?? ""
        )
      },
      set: { favorite in
        guard let group = modelGroups.first(where: { $0.id == favorite.harnessID }),
          let model = group.modelOption.options.first(where: { $0.value == favorite.modelValue }),
          !isCurrent(model, in: group)
        else { return }
        choose(model: model.value, in: group)
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
    .autocompleteSectionDividers(.hidden)
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .fixedSize()
    .disabled(isLoadingSettings)
    .help("Model parameters")
    .accessibilityLabel("Model parameters")
    .accessibilityValue(parameterAccessibilityValue)
    .onChange(of: isLoadingSettings) { _, isLoading in
      if isLoading { isParametersPresented = false }
    }
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
    if let pendingModelValue, let pendingModelGroupId {
      return pendingModelGroupId == group.id && pendingModelValue == model.value
    }
    return controller.activeHarnessId == group.id
      && group.modelOption.currentValue == model.value
  }

  private func choose(model value: String, in group: ModelMenuGroup) {
    isSwitchingHarness = true
    pendingModelValue = value
    pendingModelGroupId = group.id
    isPresented = false
    Task {
      if controller.activeHarnessId != group.id, controller.canChooseHarness {
        await controller.selectHarness(group.id)
      }
      if let liveModel = controller.modelOption {
        await controller.setConfigOption(liveModel.id, value)
      }
      isSwitchingHarness = false
      pendingModelValue = nil
      pendingModelGroupId = nil
    }
  }

  private var isLoadingSettings: Bool { isSwitchingHarness || controller.isResolvingModelConfiguration }

  private var settingsOptions: [SessionConfigOption] {
    ModelParameterMenu.options(from: controller.configOptions)
  }

  private var parameterAccessibilityValue: String {
    let summary = summarizedSettingsOptions.map { "\($0.name), \($0.currentName)" }
      .joined(separator: ", ")
    return summary.isEmpty ? "Default" : summary
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
      group: activeModelGroup,
      modelName: controller.modelOption?.currentName
    )
  }

  private var activeModelGroup: ModelMenuGroup? {
    guard let activeHarnessId = controller.activeHarnessId else { return modelGroups.first }
    return modelGroups.first { $0.id == activeHarnessId } ?? modelGroups.first
  }

  private var parameterChipLabel: some View {
    Text(parameterChipSummary)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .contentShape(Rectangle())
  }
}
