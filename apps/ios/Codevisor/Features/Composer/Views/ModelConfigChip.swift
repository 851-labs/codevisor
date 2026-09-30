import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// Separate model and parameter controls, matching the macOS composer.
/// Models use a searchable sheet; parameters use a native menu to its right.
struct ModelConfigChip: View {
  @Environment(AppEnvironment.self) private var environment
  @Bindable var controller: SessionController
  @State private var showsPicker = false

  private var canOpenPicker: Bool {
    controller.hasModelMenu || controller.canChooseHarness
  }

  /// The chip's text when no model list is on offer at all.
  private var noModelsLabel: String {
    let needsSignIn = !environment.configCache
      .signInRequired(forServer: controller.project.serverId).isEmpty
    if needsSignIn || controller.preparationState == .failed || !controller.hasModelMenu {
      return "Select a harness…"
    }
    return "Select a model"
  }

  /// The controller's in-flight pick, in the sheet's vocabulary.
  private var pendingSelection: PendingModelSelection? {
    controller.pendingModelPick.map {
      PendingModelSelection(groupId: $0.harnessId, modelValue: $0.value, modelName: $0.name)
    }
  }

  var body: some View {
    let presentation = controller.modelPickerPresentation
    Group {
      // One spinner at most across both chips (see ModelPickerPresentation).
      if presentation.modelChip == .loading {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Loading models")
      } else {
        HStack(spacing: 10) {
          if canOpenPicker {
            modelButton(presentation)
          }
          if presentation.showsSettingsChip, !settingsOptions.isEmpty || presentation.showsSettingsSpinner {
            parametersMenu(presentation)
          }
        }
      }
    }
    // Keep the presenter mounted while the catalog changes. A conditional
    // presenter caused the sheet to dismiss as soon as an auth-only result
    // removed the last model menu.
    // A popover anchored to the chip on iPad; compact width adapts it to
    // the same half-height sheet as before.
    .popover(isPresented: $showsPicker) {
      ModelPickerSheet(controller: controller, pending: pendingSelection, onChoose: choose)
        .frame(idealWidth: 400, idealHeight: 560)
    }
  }

  /// Picking a model under another harness selects that harness first (new
  /// chats only), then applies the model. The sheet is already gone by the
  /// time this runs; the controller names the pick on the chip meanwhile.
  private func choose(_ model: SessionConfigSelectOption, in groupId: String) {
    Task {
      await controller.chooseModel(model.value, name: model.name, harnessId: groupId)
    }
  }

  private func modelButton(_ presentation: ModelPickerPresentation) -> some View {
    let hasSelection = controller.selectedModelName != nil
    let title =
      controller.hasModelMenu || controller.pendingModelPick != nil
      ? presentation.modelChipTitle ?? "Select a model" : noModelsLabel
    return Button {
      showsPicker = true
    } label: {
      HStack(spacing: 5) {
        if hasSelection, let harnessId = controller.pendingModelPick?.harnessId ?? controller.activeHarnessId {
          HarnessIconView(harnessId: harnessId, size: 14)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        Text(title)
          .fontWeight(.medium)
          .foregroundStyle(hasSelection ? .primary : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .scaledFrame(height: 30, relativeTo: .callout)
      .contentShape(Rectangle())
      .expandedHitTarget(base: 30)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Capsule())
    .accessibilityLabel("Model")
    .accessibilityValue(title)
  }

  private var settingsOptions: [SessionConfigOption] {
    controller.thoughtLevelOptions
      + (controller.speedOption.map { [$0] } ?? [])
      + controller.pickerOptions
  }

  /// The chip's text. While settings are loading with nothing to name yet,
  /// the spinner alone is the label.
  private func parameterSummary(_ presentation: ModelPickerPresentation) -> String? {
    let summary = settingsOptions.filter { option in
      let isSpeed = option.category == SessionConfigOption.Category.speed || option.id == "speed"
      return !isSpeed || option.currentValue == "fast"
    }.map(\.currentName).joined(separator: " · ")
    guard summary.isEmpty else { return summary }
    return presentation.showsSettingsSpinner ? nil : "Options"
  }

  private func parametersMenu(_ presentation: ModelPickerPresentation) -> some View {
    Menu {
      ForEach(settingsOptions) { option in
        Section(option.name) {
          ForEach(option.options) { value in
            Toggle(value.name, isOn: selection(for: option, value: value.value))
          }
        }
      }
    } label: {
      HStack(spacing: 5) {
        if let summary = parameterSummary(presentation) {
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
      .scaledFrame(height: 30, relativeTo: .callout)
      .contentShape(Rectangle())
      .expandedHitTarget(base: 30)
    }
    .menuOrder(.fixed)
    .buttonStyle(.plain)
    .pointerHighlight(Capsule())
    .layoutPriority(1)
    // Picks made while the harness connects are staged, not dropped, and
    // an in-flight model pick must not lock the menu.
    .accessibilityLabel("Model parameters")
    .accessibilityValue(
      settingsOptions.map { "\($0.name), \($0.currentName)" }.joined(separator: ", ")
        + (presentation.showsSettingsSpinner ? ", updating" : "")
    )
  }

  private func selection(for option: SessionConfigOption, value: String) -> Binding<Bool> {
    Binding(
      get: { (controller.configOptions.first { $0.id == option.id }?.currentValue ?? option.currentValue) == value },
      set: { isSelected in
        // Each section is single-select; tapping its checked item keeps it selected.
        guard isSelected else { return }
        Task { await controller.setConfigOption(option.id, value) }
      }
    )
  }
}

/// A model pick that has been handed to the controller but not confirmed by
/// the harness yet. Shared by the chip (label + spinner) and the sheet (the
/// row's checkmark slot) so both agree on what "current" means meanwhile.
struct PendingModelSelection: Equatable {
  let groupId: String
  let modelValue: String
  let modelName: String
}
