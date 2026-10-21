import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct ModelConfigChip: View {
  @Environment(AppEnvironment.self) private var environment
  @Bindable var controller: SessionController
  @State private var showsPicker = false

  private var canOpenPicker: Bool {
    controller.hasModelMenu || controller.canChooseHarness
  }

  private var noModelsLabel: String {
    let needsSignIn = !environment.configCache
      .signInRequired(forServer: controller.project.serverId).isEmpty
    if needsSignIn || controller.preparationState == .failed || !controller.hasModelMenu {
      return "Select a harness…"
    }
    return "Select a model"
  }

  private var pendingSelection: PendingModelSelection? {
    controller.pendingModelPick.map {
      PendingModelSelection(groupId: $0.harnessId, modelValue: $0.value, modelName: $0.name)
    }
  }

  var body: some View {
    let presentation = controller.modelPickerPresentation
    Group {
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
    .popover(isPresented: $showsPicker) {
      ModelPickerSheet(controller: controller, pending: pendingSelection, onChoose: choose)
        .frame(idealWidth: 400, idealHeight: 560)
    }
  }

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
          HarnessGlyph(harnessId: harnessId, fallbackSymbolName: "cpu")
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
        guard isSelected else { return }
        Task { await controller.setConfigOption(option.id, value) }
      }
    )
  }
}

struct PendingModelSelection: Equatable {
  let groupId: String
  let modelValue: String
  let modelName: String
}
