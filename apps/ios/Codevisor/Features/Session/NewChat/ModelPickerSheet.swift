import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// A searchable model picker. Thinking, speed, and other parameters live
/// in the composer’s separate native menu.
struct ModelPickerSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  @Bindable var controller: SessionController

  @State private var search = ""
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
  /// chats only), then applies the model and returns to the composer.
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
      dismiss()
    }
  }

}
