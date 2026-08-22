import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// One model-centric control shared by draft and connected composers. Models
/// scroll independently from the controls owned by the selected model, so a
/// large catalog never buries reasoning, speed, context, or thinking toggles.
struct ModelConfigMenu: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings
    @Bindable var controller: SessionController

    @State private var isPresented = false
    @State private var modelSearch = ""
    @State private var isSwitchingHarness = false
    @State private var pendingModelValue: String?
    @State private var pendingModelGroupId: String?

    private struct HarnessGroup: Identifiable {
        let id: String
        let name: String
        let symbolName: String
        let modelOption: SessionConfigOption
    }

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
        } else if !modelGroups.isEmpty || controller.hasModelMenu || !settingsOptions.isEmpty {
            Button {
                isPresented.toggle()
            } label: {
                chipLabel
            }
            .buttonStyle(HoverIconButtonStyle(shape: .chip))
            .fixedSize()
            .help("Model and settings")
            .accessibilityLabel("Model settings")
            .accessibilityValue(accessibilityValue)
            .popover(
                isPresented: $isPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                configurationPopover
            }
        }
    }
}

private extension ModelConfigMenu {
    private var configurationPopover: some View {
        HStack(spacing: 0) {
            modelColumn
                .frame(width: 300)

            Divider()

            settingsColumn
                .frame(width: 320)
        }
        .frame(height: 410)
    }

    private var modelColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose model")
                    .font(.headline)

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search models", text: $modelSearch)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.secondary.opacity(0.09))
                )
            }
            .padding(14)

            Divider()

            if filteredModelGroups.isEmpty {
                ContentUnavailableView.search(text: modelSearch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredModelGroups) { group in
                            modelGroup(group)
                        }
                    }
                    .padding(8)
                }
            }

            Divider()

            Button(action: showHarnessSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .frame(width: 16)
                    Text("Manage Harnesses…")
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .help("Open Harness Settings")
        }
    }

    private func showHarnessSettings() {
        isPresented = false
        SettingsRouter.shared.showHarnesses(machineId: controller.project.serverId)
        openSettings()
    }

    private func modelGroup(_ group: HarnessGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                HarnessIcon(
                    harnessId: group.id,
                    fallbackSymbolName: group.symbolName,
                    size: 14
                )
                .frame(width: 16, height: 16)
                Text(group.name)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)

            ForEach(matchingModels(in: group)) { model in
                modelRow(model, in: group)
            }
        }
    }

    private func modelRow(_ model: SessionConfigSelectOption, in group: HarnessGroup) -> some View {
        let isSelected = isCurrent(model, in: group)
        return ModelMenuRow(
            model: model,
            isSelected: isSelected,
            isDisabled: isSwitchingHarness
        ) {
            guard !isSelected else { return }
            choose(model: model.value, in: group)
        }
    }

    @ViewBuilder
    private var settingsColumn: some View {
        if isLoadingSettings {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading settings…")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings for")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(controller.modelOption?.currentName ?? "this model")
                        .font(.headline)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)

                Divider()

                if settingsOptions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("No additional settings")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(settingsOptions) { option in
                                settingControl(option)
                            }
                        }
                        .padding(14)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func settingControl(_ option: SessionConfigOption) -> some View {
        if option.category == SessionConfigOption.Category.thoughtLevel {
            reasoningControl(option)
        } else if let toggleValues = toggleValues(for: option) {
            Toggle(
                isOn: Binding(
                    get: {
                        controller.configOptions.first { $0.id == option.id }?.currentValue
                            == toggleValues.on
                    },
                    set: { isOn in
                        Task {
                            await controller.setConfigOption(
                                option.id,
                                isOn ? toggleValues.on : toggleValues.off
                            )
                        }
                    }
                )
            ) {
                settingLabel(option)
            }
            .toggleStyle(.switch)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                settingLabel(option)

                if shouldUseSegments(option) {
                    Picker(option.name, selection: selectionBinding(for: option)) {
                        ForEach(option.options) { value in
                            Text(value.name).tag(value.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                } else {
                    Picker(option.name, selection: selectionBinding(for: option)) {
                        ForEach(option.options) { value in
                            Text(value.name).tag(value.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func reasoningControl(_ option: SessionConfigOption) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                settingLabel(option)
                Spacer(minLength: 12)
                Text(currentValueName(for: option))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: reasoningSelectionBinding(for: option),
                in: 0...Double(max(option.options.count - 1, 0)),
                step: 1
            )
            .accessibilityLabel(option.name)
            .accessibilityValue(currentValueName(for: option))
        }
    }

    private func settingLabel(_ option: SessionConfigOption) -> some View {
        Text(option.name)
            .font(.callout.weight(.medium))
    }

    private func selectionBinding(for option: SessionConfigOption) -> Binding<String> {
        Binding(
            get: {
                controller.configOptions.first { $0.id == option.id }?.currentValue
                    ?? option.currentValue
            },
            set: { value in
                Task { await controller.setConfigOption(option.id, value) }
            }
        )
    }

    private func reasoningSelectionBinding(for option: SessionConfigOption) -> Binding<Double> {
        Binding(
            get: {
                Double(
                    option.options.firstIndex { $0.value == currentValue(for: option) }
                        ?? 0
                )
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

    private var modelGroups: [HarnessGroup] {
        let serverId = controller.project.serverId
        if controller.canChooseHarness {
            let capabilities = environment.configCache.capabilities(forServer: serverId)
            return controller.harnesses.compactMap { harness in
                let options: [SessionConfigOption]
                if harness.id == controller.activeHarnessId {
                    options = controller.configOptions
                } else if let capability = capabilities.first(where: {
                    $0.harness.id == harness.id
                }) {
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
                return HarnessGroup(
                    id: harness.id,
                    name: harness.name,
                    symbolName: harness.symbolName,
                    modelOption: model
                )
            }
        }
        guard let model = controller.modelOption else { return [] }
        let harness = controller.selectedHarness
        return [
            HarnessGroup(
                id: controller.activeHarnessId ?? "active",
                name: harness?.name ?? "Model",
                symbolName: harness?.symbolName ?? "sparkle",
                modelOption: model
            )
        ]
    }

    private var filteredModelGroups: [HarnessGroup] {
        modelGroups.filter { !matchingModels(in: $0).isEmpty }
    }

    private func matchingModels(in group: HarnessGroup) -> [SessionConfigSelectOption] {
        guard !modelSearch.isEmpty else { return group.modelOption.options }
        if group.name.localizedCaseInsensitiveContains(modelSearch) {
            return group.modelOption.options
        }
        return group.modelOption.options.filter {
            $0.name.localizedCaseInsensitiveContains(modelSearch)
                || $0.value.localizedCaseInsensitiveContains(modelSearch)
        }
    }

    private func isCurrent(_ model: SessionConfigSelectOption, in group: HarnessGroup) -> Bool {
        if let pendingModelValue, let pendingModelGroupId {
            return pendingModelGroupId == group.id && pendingModelValue == model.value
        }
        return group.id == controller.activeHarnessId
            && group.modelOption.currentValue == model.value
    }

    private func choose(model value: String, in group: HarnessGroup) {
        isSwitchingHarness = true
        pendingModelValue = value
        pendingModelGroupId = group.id
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

    private var isLoadingSettings: Bool {
        isSwitchingHarness || controller.isResolvingModelConfiguration
    }

    private var settingsOptions: [SessionConfigOption] {
        let order = [
            SessionConfigOption.Category.thoughtLevel: 0,
            SessionConfigOption.Category.speed: 1,
            SessionConfigOption.Category.modelConfig: 2,
        ]
        return controller.configOptions
            .filter { option in
                !option.options.isEmpty
                    && option.category != SessionConfigOption.Category.model
                    && option.category != SessionConfigOption.Category.mode
                    && option.id != "model"
                    && option.id != "mode"
            }
            .sorted { left, right in
                let leftOrder = order[left.category ?? ""] ?? 99
                let rightOrder = order[right.category ?? ""] ?? 99
                if leftOrder == rightOrder { return left.name < right.name }
                return leftOrder < rightOrder
            }
    }

    private var accessibilityValue: String {
        ([controller.modelOption?.currentName].compactMap { $0 }
            + settingsOptions.map { "\($0.name), \($0.currentName)" })
            .joined(separator: ", ")
    }

    private var chipLabel: some View {
        HStack(spacing: 5) {
            if let model = controller.modelOption {
                Text(model.currentName)
                    .foregroundStyle(.primary)
            }
            ForEach(controller.thoughtLevelOptions) { option in
                Text(option.currentName)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct ModelMenuRow: View {
    let model: SessionConfigSelectOption
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(model.name)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        return isHovered ? Color.primary.opacity(0.06) : .clear
    }
}
