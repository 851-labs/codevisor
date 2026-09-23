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
  /// The pick most recently handed to the controller. The chip shows it
  /// (with a spinner) until the task that applied it finishes; a newer
  /// pick supersedes an older in-flight one instead of waiting on it.
  @State private var pendingSelection: PendingModelSelection?
  @State private var selectionRevision: UInt64 = 0

  private var canOpenPicker: Bool {
    controller.hasModelMenu || controller.canChooseHarness
  }

  private var fallbackLabel: String {
    let needsSignIn = !environment.configCache
      .signInRequired(forServer: controller.project.serverId).isEmpty
    if needsSignIn || controller.preparationState == .failed {
      return "Select a harness…"
    }
    return "Choose model"
  }

  var body: some View {
    Group {
      if controller.isLoadingModelMenu {
        ProgressView()
          .controlSize(.small)
      } else {
        HStack(spacing: 10) {
          if canOpenPicker {
            modelButton
          }
          if !settingsOptions.isEmpty {
            parametersMenu
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
  /// time this runs; the chip carries the pending state.
  private func choose(_ model: SessionConfigSelectOption, in groupId: String) {
    selectionRevision &+= 1
    let revision = selectionRevision
    pendingSelection = PendingModelSelection(
      groupId: groupId,
      modelValue: model.value,
      modelName: model.name
    )
    Task {
      if controller.activeHarnessId != groupId, controller.canChooseHarness {
        await controller.selectHarness(groupId)
      }
      if let live = controller.modelOption {
        await controller.setConfigOption(live.id, model.value)
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

  private var modelButton: some View {
    Button {
      showsPicker = true
    } label: {
      HStack(spacing: 5) {
        if let harnessId = pendingSelection?.groupId
          ?? (controller.modelOption != nil ? controller.activeHarnessId : nil)
        {
          HarnessIconView(harnessId: harnessId, size: 14)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        Text(pendingSelection?.modelName ?? controller.modelOption?.currentName ?? fallbackLabel)
          .fontWeight(.medium)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
        if pendingSelection != nil {
          ProgressView()
            .controlSize(.mini)
            .accessibilityHidden(true)
        }
      }
      .scaledFrame(height: 30, relativeTo: .callout)
      .contentShape(Rectangle())
      .expandedHitTarget(base: 30)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Capsule())
    .accessibilityLabel("Model")
    .accessibilityValue(
      pendingSelection.map { "\($0.modelName), updating" }
        ?? controller.modelOption?.currentName ?? fallbackLabel
    )
  }

  private var settingsOptions: [SessionConfigOption] {
    controller.thoughtLevelOptions
      + (controller.speedOption.map { [$0] } ?? [])
      + controller.pickerOptions
  }

  private var parameterSummary: String {
    let summary = settingsOptions.filter { option in
      let isSpeed = option.category == SessionConfigOption.Category.speed || option.id == "speed"
      return !isSpeed || option.currentValue == "fast"
    }.map(\.currentName).joined(separator: " · ")
    return summary.isEmpty ? "Options" : summary
  }

  private var parametersMenu: some View {
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
        Text(parameterSummary)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if isRefreshingParameters {
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
    // Only a harness that is still connecting cannot take a change (the
    // controller drops it); an in-flight model pick must not lock the menu.
    .disabled(controller.isConnectingToHarness)
    .accessibilityLabel("Model parameters")
    .accessibilityValue(
      settingsOptions.map { "\($0.name), \($0.currentName)" }.joined(separator: ", ")
        + (isRefreshingParameters ? ", updating" : "")
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
