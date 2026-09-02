import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// A searchable, navigation-based model picker. Model-specific controls use
/// native inline form controls so every setting remains visible and touch-friendly.
struct ModelPickerSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  @Bindable var controller: SessionController

  @State private var search = ""
  @State private var showsModelSettings = false
  @State private var isSwitchingHarness = false
  /// The model value tapped while a cross-harness switch is in flight, so
  /// that row shows the progress spinner in its checkmark slot.
  @State private var pendingModelValue: String?
  @State private var pendingModelGroupId: String?

  private struct HarnessGroup: Identifiable {
    let id: String
    let name: String
    let modelOption: SessionConfigOption
  }

  private var groups: [HarnessGroup] {
    let serverId = controller.project.serverId
    if controller.canChooseHarness {
      // Derived straight from the per-machine cache — server-correct by
      // construction; see ModelConfigMenu on macOS.
      return environment.configCache.capabilities(forServer: serverId).compactMap { capability in
        let harness = capability.harness
        let options: [SessionConfigOption]
        if harness.id == controller.activeHarnessId {
          options = controller.configOptions
        } else if !capability.configOptions.isEmpty {
          options = capability.configOptions
        } else {
          options = environment.configCache.options(forHarness: harness.id, onServer: serverId)
        }
        guard
          let model = options.first(where: {
            $0.category == SessionConfigOption.Category.model && !$0.options.isEmpty
          })
        else { return nil }
        return HarnessGroup(id: harness.id, name: harness.name, modelOption: model)
      }
    }
    if let model = controller.modelOption {
      let name = controller.selectedHarness?.name ?? "Model"
      return [HarnessGroup(id: controller.activeHarnessId ?? "active", name: name, modelOption: model)]
    }
    return []
  }

  var body: some View {
    NavigationStack {
      modelStep
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
          if showsUnavailableState {
            ToolbarItem(placement: .confirmationAction) {
              Button {
                Task { await controller.refreshHarnessCapabilities() }
              } label: {
                Image(systemName: "arrow.clockwise")
              }
              .accessibilityLabel("Retry loading models")
              .disabled(controller.isRefreshingHarnessCapabilities)
            }
          }
        }
        .navigationDestination(isPresented: $showsModelSettings) {
          ModelSettingsScreen(controller: controller, done: { dismiss() })
        }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .interactiveDismissDisabled(isSwitchingHarness)
  }

  @ViewBuilder
  private var modelStep: some View {
    if controller.isLoadingModelMenu, groups.isEmpty {
      loadingStep("Loading models…")
    } else if controller.preparationState == .failed, groups.isEmpty {
      unavailableStep
    } else if groups.isEmpty {
      emptyStep
    } else {
      List {
        ForEach(groups) { group in
          let values = matchingValues(in: group)
          if !values.isEmpty {
            Section {
              ForEach(values) { value in
                Button {
                  choose(model: value.value, in: group)
                } label: {
                  HStack {
                    Text(value.name)
                      .foregroundStyle(Color.primary)
                    Spacer()
                    if isSwitchingHarness,
                      pendingModelValue == value.value,
                      pendingModelGroupId == group.id
                    {
                      // A cross-harness pick shows
                      // progress while the harness (and
                      // its thinking levels) loads.
                      ProgressView()
                        .controlSize(.small)
                    } else if isCurrent(value, in: group) {
                      Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                    }
                  }
                }
                .disabled(isSwitchingHarness)
              }
            } header: {
              HStack(spacing: 6) {
                HarnessIconView(harnessId: group.id, size: 14)
                Text(group.name)
              }
            }
          }
        }
        if search.isEmpty, let machine = machine {
          Section {
            NavigationLink {
              HarnessMachineSettingsScreen(machine: machine)
            } label: {
              Label("Manage Harnesses", systemImage: "cpu")
            }
          }
        }
      }
      .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
    }
  }

  private var machine: CodevisorMachine? {
    environment.machines.machine(for: controller.project.serverId)
  }

  private var showsUnavailableState: Bool {
    controller.preparationState == .failed
      && groups.isEmpty
  }

  private var unavailableStep: some View {
    ContentUnavailableView {
      Label("Models Unavailable", systemImage: "exclamationmark.triangle")
    } description: {
      Text("Codevisor couldn’t load models from this machine.")
    } actions: {
      manageHarnessesLink
    }
  }

  private var emptyStep: some View {
    ContentUnavailableView {
      Label("No Models Available", systemImage: "cpu")
    } description: {
      Text("Install or finish setting up a harness on this machine.")
    } actions: {
      manageHarnessesLink
    }
  }

  @ViewBuilder
  private var manageHarnessesLink: some View {
    if let machine {
      NavigationLink {
        HarnessMachineSettingsScreen(machine: machine)
      } label: {
        Text("Manage Harnesses…")
      }
      .buttonStyle(.borderedProminent)
    }
  }

  /// A centered spinner holding a step's place while its options load.
  private func loadingStep(_ label: String) -> some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(label)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemGroupedBackground))
  }

  private func matchingValues(in group: HarnessGroup) -> [SessionConfigSelectOption] {
    guard !search.isEmpty else { return group.modelOption.options }
    return group.modelOption.options.filter {
      $0.name.localizedCaseInsensitiveContains(search)
        || group.name.localizedCaseInsensitiveContains(search)
    }
  }

  private func isCurrent(_ value: SessionConfigSelectOption, in group: HarnessGroup) -> Bool {
    group.id == controller.activeHarnessId && group.modelOption.currentValue == value.value
  }

  // MARK: - Selection

  /// Picking a model under another harness selects that harness first (new
  /// chats only), then applies the model and walks the remaining steps.
  private func choose(model value: String, in group: HarnessGroup) {
    isSwitchingHarness = true
    pendingModelValue = value
    pendingModelGroupId = group.id
    Task {
      if controller.activeHarnessId != group.id, controller.canChooseHarness {
        await controller.selectHarness(group.id)
      }
      if let live = controller.modelOption {
        await controller.setConfigOption(live.id, value)
      }
      isSwitchingHarness = false
      pendingModelValue = nil
      pendingModelGroupId = nil
      if configurableOptions.isEmpty {
        dismiss()
      } else {
        showsModelSettings = true
      }
    }
  }

  private var configurableOptions: [SessionConfigOption] {
    controller.thoughtLevelOptions
      + (controller.speedOption.map { [$0] } ?? [])
      + controller.pickerOptions
  }
}

private struct ModelSettingsScreen: View {
  @Bindable var controller: SessionController
  let done: () -> Void

  private var options: [SessionConfigOption] {
    controller.thoughtLevelOptions
      + (controller.speedOption.map { [$0] } ?? [])
      + controller.pickerOptions
  }

  var body: some View {
    Form {
      Section {
        ForEach(options) { option in
          settingControl(option)
            .padding(.vertical, 4)
        }
      }
    }
    .navigationTitle("Model Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done", action: done)
      }
    }
  }

  @ViewBuilder
  private func settingControl(_ option: SessionConfigOption) -> some View {
    if option.category == SessionConfigOption.Category.thoughtLevel,
      option.options.count > 1
    {
      VStack(alignment: .leading, spacing: 10) {
        settingHeader(option)
        Slider(
          value: reasoningSelectionBinding(for: option),
          in: 0...Double(option.options.count - 1),
          step: 1
        )
        .accessibilityLabel(option.name)
        .accessibilityValue(currentValueName(for: option))
      }
    } else if let toggleValues = toggleValues(for: option) {
      Toggle(
        option.name,
        isOn: Binding(
          get: { currentValue(for: option) == toggleValues.on },
          set: { isOn in
            Task {
              await controller.setConfigOption(
                option.id,
                isOn ? toggleValues.on : toggleValues.off
              )
            }
          }
        )
      )
    } else if shouldUseSegments(option) {
      VStack(alignment: .leading, spacing: 10) {
        settingHeader(option)
        AccentSegmentedPicker(
          options: option.options,
          selection: selectionBinding(for: option)
        )
        .frame(maxWidth: .infinity)
        .accessibilityLabel(option.name)
      }
    } else {
      Picker(option.name, selection: selectionBinding(for: option)) {
        ForEach(option.options) { value in
          Text(value.name).tag(value.value)
        }
      }
      .pickerStyle(.menu)
    }
  }

  private func settingHeader(_ option: SessionConfigOption) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(option.name)
        .font(.callout.weight(.medium))
      Spacer(minLength: 12)
      Text(currentValueName(for: option))
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
    }
  }

  private func selectionBinding(for option: SessionConfigOption) -> Binding<String> {
    Binding(
      get: { currentValue(for: option) },
      set: { value in
        guard value != currentValue(for: option) else { return }
        Task { await controller.setConfigOption(option.id, value) }
      }
    )
  }

  private func reasoningSelectionBinding(for option: SessionConfigOption) -> Binding<Double> {
    Binding(
      get: {
        Double(option.options.firstIndex { $0.value == currentValue(for: option) } ?? 0)
      },
      set: { value in
        let index = min(max(Int(value.rounded()), 0), option.options.count - 1)
        let selection = option.options[index].value
        guard selection != currentValue(for: option) else { return }
        Task { await controller.setConfigOption(option.id, selection) }
      }
    )
  }

  private func currentValue(for option: SessionConfigOption) -> String {
    controller.configOptions.first { $0.id == option.id }?.currentValue
      ?? option.currentValue
  }

  private func currentValueName(for option: SessionConfigOption) -> String {
    let value = currentValue(for: option)
    return option.options.first { $0.value == value }?.name ?? value
  }

  private func toggleValues(for option: SessionConfigOption) -> (off: String, on: String)? {
    guard option.category != SessionConfigOption.Category.speed,
      option.options.count == 2
    else { return nil }
    let values = Dictionary(
      uniqueKeysWithValues: option.options.map { ($0.value.lowercased(), $0.value) }
    )
    for pair in [("off", "on"), ("false", "true"), ("disabled", "enabled")] {
      if let off = values[pair.0], let on = values[pair.1] {
        return (off, on)
      }
    }
    return nil
  }

  private func shouldUseSegments(_ option: SessionConfigOption) -> Bool {
    option.options.count <= 4
      && option.options.reduce(0) { $0 + $1.name.count } <= 34
  }
}

/// SwiftUI's segmented picker keeps a neutral selected fill on current iOS
/// even when `.tint` is applied. Use the native UIKit control directly so its
/// selected segment can follow Codevisor's accent while retaining standard
/// segmented-control sizing, focus, and accessibility behavior.
private struct AccentSegmentedPicker: UIViewRepresentable {
  let options: [SessionConfigSelectOption]
  @Binding var selection: String

  func makeCoordinator() -> Coordinator {
    Coordinator(options: options, selection: $selection)
  }

  func makeUIView(context: Context) -> UISegmentedControl {
    let control = UISegmentedControl(items: options.map(\.name))
    control.setContentHuggingPriority(.defaultLow, for: .horizontal)
    control.addTarget(
      context.coordinator,
      action: #selector(Coordinator.selectionChanged(_:)),
      for: .valueChanged
    )
    updateAppearance(control)
    return control
  }

  func updateUIView(_ control: UISegmentedControl, context: Context) {
    context.coordinator.options = options
    context.coordinator.selection = $selection

    if control.numberOfSegments != options.count {
      control.removeAllSegments()
      for (index, option) in options.enumerated() {
        control.insertSegment(withTitle: option.name, at: index, animated: false)
      }
    } else {
      for (index, option) in options.enumerated()
      where control.titleForSegment(at: index) != option.name {
        control.setTitle(option.name, forSegmentAt: index)
      }
    }

    control.selectedSegmentIndex =
      options.firstIndex { $0.value == selection }
      ?? UISegmentedControl.noSegment
    updateAppearance(control)
  }

  private func updateAppearance(_ control: UISegmentedControl) {
    let accentColor = UIColor(Color.accentColor)
    control.tintColor = accentColor
    control.selectedSegmentTintColor = accentColor
    control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
  }

  final class Coordinator: NSObject {
    var options: [SessionConfigSelectOption]
    var selection: Binding<String>

    init(options: [SessionConfigSelectOption], selection: Binding<String>) {
      self.options = options
      self.selection = selection
    }

    @objc func selectionChanged(_ sender: UISegmentedControl) {
      guard options.indices.contains(sender.selectedSegmentIndex) else { return }
      selection.wrappedValue = options[sender.selectedSegmentIndex].value
    }
  }
}
