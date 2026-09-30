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

  var body: some View {
    let presentation = controller.modelPickerPresentation
    // One spinner at most across both chips (see ModelPickerPresentation).
    if presentation.modelChip == .loading {
      ProgressView()
        .controlSize(.small)
        .frame(minWidth: 96)
        .help("Loading models")
        .accessibilityLabel("Loading models")
    } else if !modelGroups.isEmpty || !signInRequiredHarnesses.isEmpty || !settingsOptions.isEmpty {
      HStack(spacing: 10) {
        if !modelGroups.isEmpty || !signInRequiredHarnesses.isEmpty {
          modelButton(presentation)
        }
        if presentation.showsSettingsChip, !settingsOptions.isEmpty || presentation.showsSettingsSpinner {
          parametersMenu(presentation)
        }
      }
    }
  }
}

private extension ModelConfigMenu {
  private func modelButton(_ presentation: ModelPickerPresentation) -> some View {
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
      modelChipLabel(presentation)
    }
    .autocompleteSearchLabel("Search models")
    .autocompleteEmptyMessage("No matching models")
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .hoverChipOverflow()
    .fixedSize(horizontal: false, vertical: true)
    .help("Choose model")
    .accessibilityLabel("Model")
    .accessibilityValue(presentation.modelChipTitle ?? "Loading")
  }

  private var modelSelection: Binding<ModelPickerFavorite> {
    Binding(
      get: {
        if let pick = controller.pendingModelPick {
          return ModelPickerFavorite(harnessID: pick.harnessId, modelValue: pick.value)
        }
        return ModelPickerFavorite(
          harnessID: controller.activeHarnessId ?? "active",
          modelValue: controller.selectedModelName == nil
            ? "" : controller.modelOption?.currentValue ?? ""
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

  private func parametersMenu(_ presentation: ModelPickerPresentation) -> some View {
    Autocomplete.Menu(isPresented: $isParametersPresented) {
      for option in settingsOptions {
        Autocomplete.Picker(option.name, id: option.id, selection: parameterSelection(option), options: option.options)
        { value in
          Autocomplete.Choice(value.name, value: value.value).searchTerms([value.value])
        }
      }
    } label: {
      parameterChipLabel(presentation)
    }
    .autocompleteSearchLabel("Search model parameters")
    .autocompleteEmptyMessage("No matching parameters")
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .hoverChipOverflow()
    .fixedSize()
    .help("Model parameters")
    .accessibilityLabel("Model parameters")
    .accessibilityValue(parameterAccessibilityValue(presentation))
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
    if let pick = controller.pendingModelPick {
      return pick.harnessId == group.id && pick.value == model.value
    }
    return controller.activeHarnessId == group.id
      && controller.selectedModelName != nil
      && group.modelOption.currentValue == model.value
  }

  /// The controller names the pick on the chip immediately, validates it
  /// against the live list after any harness switch (staging it if the list
  /// lags), and resolves the model's settings behind a single spinner.
  private func choose(_ model: SessionConfigSelectOption, in group: ModelMenuGroup) {
    isPresented = false
    Task {
      await controller.chooseModel(model.value, name: model.name, harnessId: group.id)
    }
  }

  private var settingsOptions: [SessionConfigOption] {
    ModelParameterMenu.options(from: controller.configOptions)
  }

  private func parameterAccessibilityValue(_ presentation: ModelPickerPresentation) -> String {
    let summary = summarizedSettingsOptions.map { "\($0.name), \($0.currentName)" }
      .joined(separator: ", ")
    guard !summary.isEmpty else { return presentation.showsSettingsSpinner ? "Loading" : "Default" }
    return presentation.showsSettingsSpinner ? "\(summary), updating" : summary
  }

  private var summarizedSettingsOptions: [SessionConfigOption] {
    ModelParameterMenu.summarized(settingsOptions)
  }

  /// The chip's text. While settings are loading with nothing to name yet,
  /// the spinner alone is the label.
  private func parameterChipSummary(_ presentation: ModelPickerPresentation) -> String? {
    let summary = summarizedSettingsOptions.map(\.currentName).joined(separator: " · ")
    guard summary.isEmpty else { return summary }
    return presentation.showsSettingsSpinner ? nil : "Options"
  }

  private func modelChipLabel(_ presentation: ModelPickerPresentation) -> some View {
    ModelPickerChipLabel(
      group: pendingModelGroup ?? activeModelGroup,
      title: presentation.modelChipTitle ?? "Select a model",
      hasSelection: controller.selectedModelName != nil
    )
  }

  private var pendingModelGroup: ModelMenuGroup? {
    guard let pick = controller.pendingModelPick else { return nil }
    return modelGroups.first { $0.id == pick.harnessId }
  }

  private var activeModelGroup: ModelMenuGroup? {
    guard let activeHarnessId = controller.activeHarnessId else { return modelGroups.first }
    return modelGroups.first { $0.id == activeHarnessId } ?? modelGroups.first
  }

  private func parameterChipLabel(_ presentation: ModelPickerPresentation) -> some View {
    HStack(spacing: 5) {
      if let summary = parameterChipSummary(presentation) {
        Text(summary)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if presentation.showsSettingsSpinner {
        ProgressView()
          .controlSize(.mini)
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
  }
}
