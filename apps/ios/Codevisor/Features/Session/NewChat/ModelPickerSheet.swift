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
  /// A pick the composer is still applying; its row shows a spinner in the
  /// checkmark slot if the sheet is reopened before it settles.
  var pending: PendingModelSelection?
  /// Tapping a row hands the pick to the composer chip, which owns the
  /// in-flight state, and the sheet closes right away.
  let onChoose: (SessionConfigSelectOption, String) -> Void

  /// Pushed screens live here, not in a view-destination link: the model
  /// step re-branches whenever capabilities reload (returning from a
  /// browser sign-in, or the sign-in itself changing the catalog), and a
  /// link unmounted by that pops whatever it pushed — mid-auth.
  private enum Destination: Hashable {
    case manageHarnesses
  }

  @State private var path: [Destination] = []
  @State private var search = ""

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
    NavigationStack(path: $path) {
      modelStep
        .navigationDestination(for: Destination.self) { destination in
          switch destination {
          case .manageHarnesses: HarnessesSettingsScreen()
          }
        }
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
                  onChoose(value, group.id)
                  dismiss()
                } label: {
                  HStack {
                    Text(value.name)
                      .foregroundStyle(Color.primary)
                    Spacer()
                    if let pending, pending.groupId == group.id, pending.modelValue == value.value {
                      ProgressView()
                        .controlSize(.small)
                    } else if isCurrent(value, in: group) {
                      Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                    }
                  }
                }
              }
            } header: {
              HStack(spacing: 6) {
                HarnessIconView(harnessId: group.id, size: 14)
                Text(group.name)
              }
            }
          }
        }
        if search.isEmpty {
          Section {
            NavigationLink(value: Destination.manageHarnesses) {
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

  private var manageHarnessesLink: some View {
    NavigationLink(value: Destination.manageHarnesses) {
      Text("Manage Harnesses…")
    }
    .buttonStyle(.borderedProminent)
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
    if pending != nil { return false }
    return group.id == controller.activeHarnessId && group.modelOption.currentValue == value.value
  }
}
