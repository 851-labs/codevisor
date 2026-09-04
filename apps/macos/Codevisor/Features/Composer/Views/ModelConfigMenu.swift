import ACPKit
import CodevisorCore
import CodevisorUI
import Autocomplete
import SwiftUI

/// Separate model and parameter controls shared by draft and connected
/// composers. The model picker follows Xcode's searchable picker presentation
/// (via Autocomplete); parameters use a native menu grouped by option.
struct ModelConfigMenu: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.openSettings) private var openSettings
  @Bindable var controller: SessionController

  @ClientPreference("composer.favoriteModels", default: [])
  private var favoriteModelIDs: [ModelPickerFavorite]
  @State private var isPresented = false
  @State private var modelSearch = ""
  @State private var isSwitchingHarness = false
  @State private var pendingModelValue: String?
  @State private var pendingModelGroupId: String?
  @State private var highlight = Autocomplete.Highlight<ModelPickerTarget>(navigation: .menu)
  /// Measured from the unfiltered list when the popover opens so filtering
  /// never resizes it.
  @State private var presentedListHeight: CGFloat?

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
    Button {
      modelSearch = ""
      if isPresented {
        isPresented = false
      } else {
        presentedListHeight = listHeight(for: modelCatalog)
        isPresented = true
      }
    } label: {
      modelChipLabel
    }
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    // The model name is provider-owned and can be arbitrarily long. Let
    // this chip accept the toolbar's width proposal so its label can
    // truncate before it pushes the composer actions out of bounds.
    .fixedSize(horizontal: false, vertical: true)
    .disabled(isSwitchingHarness)
    .help("Choose model")
    .accessibilityLabel("Model")
    .accessibilityValue(controller.modelOption?.currentName ?? "No model selected")
    .popover(
      isPresented: $isPresented,
      attachmentAnchor: .rect(.bounds),
      arrowEdge: .bottom
    ) {
      modelPickerPopup
    }
  }

  private var parametersMenu: some View {
    Menu {
      ForEach(settingsOptions) { option in
        Section(option.name) {
          ForEach(option.options) { value in
            Toggle(
              isOn: parameterSelectionBinding(option: option, value: value.value)
            ) {
              Text(value.name)
            }
          }
        }
      }
    } label: {
      parameterChipLabel
    }
    .menuStyle(.button)
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(isLoadingSettings)
    .help("Model parameters")
    .accessibilityLabel("Model parameters")
    .accessibilityValue(parameterAccessibilityValue)
  }

  private static let footerTitle = "Manage Harnesses…"
  private static let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var modelPickerPopup: some View {
    let catalog = modelCatalog
    return Autocomplete.Root(
      highlight: highlight,
      isDisabled: isSwitchingHarness,
      showsCheckmarks: true,
      onDismiss: { isPresented = false }
    ) {
      Autocomplete.Input(
        text: $modelSearch, prompt: "Search", accessibilityLabel: "Search models", focusesOnAppear: true
      )

      Autocomplete.List(height: presentedListHeight ?? listHeight(for: catalog)) {
        if catalog.sections.isEmpty {
          Autocomplete.Empty("No matching models")
        }
        ForEach(catalog.sections) { section in
          Autocomplete.Group(section.title) {
            ForEach(section.items) { item in
              modelItem(item)
            }
          }
        }
      }

      Autocomplete.Footer {
        Autocomplete.Item(id: ModelPickerTarget.manageHarnesses, action: showHarnessSettings) { _ in
          Text(Self.footerTitle)
        }
        .help("Open Harness Settings")
      }
    }
    .frame(
      width: Self.metrics.popupWidth(fitting: catalog.allTitles + [Self.footerTitle], showsCheckmarks: true)
    )
    .onDisappear {
      presentedListHeight = nil
    }
  }

  private func modelItem(_ item: ModelPickerModelItem) -> some View {
    Autocomplete.Item(
      id: item.id,
      isSelected: isCurrent(item.model, in: item.group),
      accessibilityAction: Autocomplete.ItemAction(name: item.favoriteAction.label) { toggleFavorite(item) },
      action: { selectModelItem(item) }
    ) { _ in
      Text(item.model.name)
        .lineLimit(1)
    } accessory: { _ in
      Autocomplete.FavoriteButton(item.favoriteAction) {
        toggleFavorite(item)
      }
    }
  }

  private func listHeight(for catalog: ModelPickerCatalog) -> CGFloat {
    Self.metrics.listHeight(groupItemCounts: catalog.groupItemCounts, footerItemCount: 1)
  }

  private func selectModelItem(_ item: ModelPickerModelItem) {
    if isCurrent(item.model, in: item.group) {
      isPresented = false
    } else {
      choose(model: item.model.value, in: item.group)
    }
  }

  private var normalizedModelSearch: String {
    modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var modelCatalog: ModelPickerCatalog {
    ModelPickerCatalog(
      groups: modelGroups,
      favoriteIDs: favoriteModelIDs,
      query: normalizedModelSearch
    )
  }

  private func toggleFavorite(_ item: ModelPickerModelItem) {
    highlight.reset()
    switch item.favoriteAction {
    case .add:
      guard !favoriteModelIDs.contains(item.favorite) else { return }
      favoriteModelIDs = favoriteModelIDs + [item.favorite]
    case .remove:
      favoriteModelIDs = favoriteModelIDs.filter { $0 != item.favorite }
    }
  }

  private func showHarnessSettings() {
    isPresented = false
    SettingsRouter.shared.showHarnesses(machineId: controller.project.serverId)
    openSettings()
  }

  private func parameterSelectionBinding(
    option: SessionConfigOption,
    value: String
  ) -> Binding<Bool> {
    Binding(
      get: {
        let current =
          controller.configOptions.first { $0.id == option.id }?.currentValue
          ?? option.currentValue
        return current == value
      },
      set: { isSelected in
        guard isSelected else { return }
        Task { await controller.setConfigOption(option.id, value) }
      }
    )
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
