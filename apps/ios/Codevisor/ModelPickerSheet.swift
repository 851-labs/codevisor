import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// The model picker: a searchable sheet of models grouped by harness. Picking
/// a model walks the follow-up steps the harness supports — thinking level,
/// then speed — and closes. New chats list every ready harness (choosing a
/// model chooses its harness); existing sessions are scoped to the session's
/// harness.
struct ModelPickerSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: SessionController

    private enum Step {
        case model
        case thought
        case speed
    }

    @State private var step: Step = .model
    @State private var search = ""
    @State private var isSwitchingHarness = false

    private struct HarnessGroup: Identifiable {
        let id: String
        let name: String
        let modelOption: SessionConfigOption
    }

    private var groups: [HarnessGroup] {
        let serverId = controller.project.serverId
        if controller.canChooseHarness {
            let capabilities = environment.configCache.capabilities(forServer: serverId)
            return controller.harnesses.compactMap { harness in
                let options: [SessionConfigOption]
                if harness.id == controller.activeHarnessId {
                    options = controller.configOptions
                } else if let capability = capabilities.first(where: { $0.harness.id == harness.id }) {
                    options = capability.configOptions
                } else {
                    options = environment.configCache.options(forHarness: harness.id, onServer: serverId)
                }
                guard let model = options.first(where: {
                    $0.category == SessionConfigOption.Category.model && !$0.options.isEmpty
                }) else { return nil }
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
            Group {
                switch step {
                case .model: modelStep
                case .thought: thoughtStep
                case .speed: speedStep
                }
            }
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSwitchingHarness)
    }

    private var stepTitle: String {
        switch step {
        case .model: "Model"
        case .thought: controller.thoughtLevelOptions.first?.name ?? "Thinking"
        case .speed: "Speed"
        }
    }

    // MARK: - Steps

    private var modelStep: some View {
        List {
            ForEach(groups) { group in
                let values = matchingValues(in: group)
                if !values.isEmpty {
                    Section(group.name) {
                        ForEach(values) { value in
                            Button {
                                choose(model: value.value, in: group)
                            } label: {
                                HStack {
                                    Text(value.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if isCurrent(value, in: group) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    } else if isSwitchingHarness {
                                        // A cross-harness pick shows progress
                                        // while the harness loads.
                                        EmptyView()
                                    }
                                }
                            }
                            .disabled(isSwitchingHarness)
                        }
                    }
                }
            }
            if isSwitchingHarness {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
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

    private var thoughtStep: some View {
        List {
            if let option = controller.thoughtLevelOptions.first {
                Section(option.name) {
                    ForEach(option.options) { value in
                        Button {
                            choose(option: option, value: value.value, next: .speed)
                        } label: {
                            HStack {
                                Text(value.name).foregroundStyle(.primary)
                                Spacer()
                                if option.currentValue == value.value {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var speedStep: some View {
        List {
            if let option = controller.speedOption {
                Section("Speed") {
                    ForEach(option.options) { value in
                        Button {
                            choose(option: option, value: value.value, next: nil)
                        } label: {
                            HStack {
                                Text(value.name).foregroundStyle(.primary)
                                Spacer()
                                if option.currentValue == value.value {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Selection

    /// Picking a model under another harness selects that harness first (new
    /// chats only), then applies the model and walks the remaining steps.
    private func choose(model value: String, in group: HarnessGroup) {
        isSwitchingHarness = true
        Task {
            if controller.activeHarnessId != group.id, controller.canChooseHarness {
                await controller.selectHarness(group.id)
            }
            if let live = controller.modelOption {
                await controller.setConfigOption(live.id, value)
            }
            isSwitchingHarness = false
            advanceAfterModel()
        }
    }

    private func advanceAfterModel() {
        if !controller.thoughtLevelOptions.isEmpty {
            step = .thought
        } else if controller.speedOption != nil {
            step = .speed
        } else {
            dismiss()
        }
    }

    private func choose(option: SessionConfigOption, value: String, next: Step?) {
        Task {
            await controller.setConfigOption(option.id, value)
            if next == .speed, controller.speedOption != nil {
                step = .speed
            } else {
                dismiss()
            }
        }
    }
}
