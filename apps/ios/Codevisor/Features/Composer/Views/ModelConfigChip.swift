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
    .sheet(isPresented: $showsPicker) {
      ModelPickerSheet(controller: controller)
    }
  }

  private var modelButton: some View {
    Button {
      showsPicker = true
    } label: {
      HStack(spacing: 5) {
        if controller.modelOption != nil, let harnessId = controller.activeHarnessId {
          HarnessIconView(harnessId: harnessId, size: 14)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        Text(controller.modelOption?.currentName ?? fallbackLabel)
          .fontWeight(.medium)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .scaledFrame(height: 30, relativeTo: .callout)
      .contentShape(Rectangle())
      .expandedHitTarget(base: 30)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Model")
    .accessibilityValue(controller.modelOption?.currentName ?? fallbackLabel)
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
      Text(parameterSummary)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .scaledFrame(height: 30, relativeTo: .callout)
        .contentShape(Rectangle())
        .expandedHitTarget(base: 30)
    }
    .menuOrder(.fixed)
    .buttonStyle(.plain)
    .layoutPriority(1)
    .disabled(controller.isResolvingModelConfiguration || controller.isConnectingToHarness)
    .accessibilityLabel("Model parameters")
    .accessibilityValue(settingsOptions.map { "\($0.name), \($0.currentName)" }.joined(separator: ", "))
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
