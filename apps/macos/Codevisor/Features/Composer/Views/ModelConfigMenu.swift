import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// Separate model and parameter controls shared by draft and connected
/// composers. The model picker follows Xcode's searchable picker presentation;
/// parameters use a native menu grouped by option.
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
    @State private var keyboardTarget: ModelPickerKeyboardTarget?
    @State private var hoverTarget: ModelPickerKeyboardTarget?
    @State private var presentedModelPickerListHeight: CGFloat?

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
                presentedModelPickerListHeight = unfilteredModelPickerListHeight
                isPresented = true
            }
        } label: {
            modelChipLabel
        }
        .buttonStyle(HoverIconButtonStyle(shape: .chip))
        .fixedSize()
        .disabled(isSwitchingHarness)
        .help("Choose model")
        .accessibilityLabel("Model")
        .accessibilityValue(controller.modelOption?.currentName ?? "No model selected")
        .popover(
            isPresented: $isPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            modelPickerPopover
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

    private var modelPickerPopover: some View {
        VStack(spacing: 0) {
            modelSearchField

            Group {
                if resolvedFavoriteModels.isEmpty, filteredModelGroups.isEmpty {
                    Text("No matching models")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(
                                alignment: .leading,
                                spacing: XcodeModelPickerMetrics.sectionSpacing
                            ) {
                                if !resolvedFavoriteModels.isEmpty {
                                    favoritesSection
                                }

                                ForEach(filteredModelGroups) { group in
                                    modelGroup(group)
                                }
                            }
                            .padding(
                                .horizontal,
                                XcodeModelPickerMetrics.listHorizontalInset
                            )
                            .padding(.vertical, XcodeModelPickerMetrics.listVerticalInset)
                            .background(ModelPickerScrollerConfigurator())
                        }
                        .scrollBounceBehavior(modelPickerScrollBounceBehavior)
                        .onChange(of: keyboardTarget) { _, target in
                            scrollKeyboardTargetIntoView(target, using: proxy)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: modelPickerListHeight)

            Divider()

            ModelPickerFooterRow(
                title: "Manage Harnesses…",
                isKeyboardHighlighted: highlightedTarget == .manageHarnesses,
                onHover: { isHovering in
                    updateHoverTarget(.manageHarnesses, isHovering: isHovering)
                },
                action: showHarnessSettings
            )
        }
        .frame(width: modelPickerPopoverWidth)
        .onAppear {
            modelSearch = ""
            if presentedModelPickerListHeight == nil {
                presentedModelPickerListHeight = unfilteredModelPickerListHeight
            }
            hoverTarget = nil
            keyboardTarget = nil
        }
        .onDisappear {
            modelSearch = ""
            presentedModelPickerListHeight = nil
            hoverTarget = nil
            keyboardTarget = nil
        }
        .onChange(of: normalizedModelSearch) {
            hoverTarget = nil
            reconcileKeyboardTarget()
        }
        .onHover { isHovering in
            if !isHovering {
                hoverTarget = nil
            }
        }
        .background {
            ModelPickerKeyMonitor(
                onMoveUp: { moveKeyboardTarget(by: -1) },
                onMoveDown: { moveKeyboardTarget(by: 1) },
                onSubmit: activateKeyboardTarget,
                onCancel: { isPresented = false }
            )
            .frame(width: 0, height: 0)
        }
    }

    private var modelSearchField: some View {
        ModelFilterField(
            text: $modelSearch,
            onMoveUp: { moveKeyboardTarget(by: -1) },
            onMoveDown: { moveKeyboardTarget(by: 1) },
            onSubmit: activateKeyboardTarget,
            onCancel: { isPresented = false }
        )
        .frame(height: XcodeModelPickerMetrics.searchFieldHeight)
        .padding(.horizontal, XcodeModelPickerMetrics.searchHorizontalInset)
        .padding(.top, XcodeModelPickerMetrics.searchTopInset)
        .padding(.bottom, XcodeModelPickerMetrics.searchBottomInset)
        .accessibilityLabel("Filter models")
    }

    private func modelGroup(_ group: ModelMenuGroup) -> some View {
        modelSection(
            title: group.name,
            items: visibleModels(in: group).map {
                ModelPickerModelItem(group: group, model: $0)
            },
            favoriteAction: .add
        )
    }

    private var favoritesSection: some View {
        modelSection(
            title: "Favorites",
            items: resolvedFavoriteModels,
            favoriteAction: .remove
        )
    }

    private func modelSection(
        title: String,
        items: [ModelPickerModelItem],
        favoriteAction: ModelPickerFavoriteAction
    ) -> some View {
        ModelPickerModelSection(
            title: title,
            items: items,
            favoriteAction: favoriteAction,
            highlightedTarget: highlightedTarget,
            isDisabled: isSwitchingHarness,
            isSelected: { isCurrent($0.model, in: $0.group) },
            onHover: { updateHoverTarget($0, isHovering: $1) },
            onFavoriteAction: { item in
                switch favoriteAction {
                case .add: favorite(item.model, in: item.group)
                case .remove: unfavorite(ModelPickerFavorite(model: item.model, group: item.group))
                }
            },
            onSelect: selectModelItem
        )
    }

    private func selectModelItem(_ item: ModelPickerModelItem) {
        if isCurrent(item.model, in: item.group) {
            isPresented = false
        } else {
            choose(model: item.model.value, in: item.group)
        }
    }

    private var visibleKeyboardTargets: [ModelPickerKeyboardTarget] {
        var targets = resolvedFavoriteModels.map {
            modelTarget($0.model, in: $0.group)
        }
        targets.append(
            contentsOf: filteredModelGroups.flatMap { group in
                visibleModels(in: group).map { modelTarget($0, in: group) }
            }
        )
        targets.append(.manageHarnesses)
        return targets
    }

    private var highlightedTarget: ModelPickerKeyboardTarget? {
        hoverTarget ?? keyboardTarget
    }

    private func modelTarget(
        _ model: SessionConfigSelectOption,
        in group: ModelMenuGroup
    ) -> ModelPickerKeyboardTarget {
        .model(groupID: group.id, value: model.value)
    }

    private func reconcileKeyboardTarget() {
        guard let keyboardTarget else { return }
        if !visibleKeyboardTargets.contains(keyboardTarget) {
            self.keyboardTarget = nil
        }
    }

    private func updateHoverTarget(
        _ target: ModelPickerKeyboardTarget,
        isHovering: Bool
    ) {
        if isHovering {
            hoverTarget = target
        } else if hoverTarget == target {
            hoverTarget = nil
        }
    }

    private func moveKeyboardTarget(by offset: Int) {
        hoverTarget = nil
        let targets = visibleKeyboardTargets
        guard !targets.isEmpty else {
            keyboardTarget = nil
            return
        }

        guard let keyboardTarget, let index = targets.firstIndex(of: keyboardTarget) else {
            self.keyboardTarget = offset < 0 ? targets.last : targets.first
            return
        }

        let nextIndex = min(max(index + offset, targets.startIndex), targets.index(before: targets.endIndex))
        self.keyboardTarget = targets[nextIndex]
    }

    private func activateKeyboardTarget() {
        guard let keyboardTarget else { return }
        switch keyboardTarget {
        case let .model(groupID, value):
            guard
                visibleKeyboardTargets.contains(keyboardTarget),
                let group = modelGroups.first(where: { $0.id == groupID }),
                let model = group.modelOption.options.first(where: {
                    $0.value == value
                })
            else { return }
            if isCurrent(model, in: group) {
                isPresented = false
            } else {
                choose(model: value, in: group)
            }
        case .manageHarnesses:
            showHarnessSettings()
        }
    }

    private func scrollKeyboardTargetIntoView(
        _ target: ModelPickerKeyboardTarget?,
        using proxy: ScrollViewProxy
    ) {
        guard let target, target != .manageHarnesses else { return }
        proxy.scrollTo(target, anchor: .center)
    }

    private var normalizedModelSearch: String {
        modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var modelPickerPopoverWidth: CGFloat {
        XcodeModelPickerMetrics.popoverWidth(for: modelGroups)
    }

    private var modelPickerListHeight: CGFloat {
        presentedModelPickerListHeight ?? unfilteredModelPickerListHeight
    }

    private var modelPickerScrollBounceBehavior: ScrollBounceBehavior {
        let contentHeight = XcodeModelPickerMetrics.listContentHeight(
            sectionItemCounts: modelCatalog.sectionItemCounts
        )
        return contentHeight > modelPickerListHeight ? .always : .basedOnSize
    }

    private var unfilteredModelPickerListHeight: CGFloat {
        modelPickerListHeight(
            for: ModelPickerCatalog(
                groups: modelGroups,
                favoriteIDs: favoriteModelIDs,
                query: ""
            )
        )
    }

    private func modelPickerListHeight(for catalog: ModelPickerCatalog) -> CGFloat {
        XcodeModelPickerMetrics.listHeight(
            sectionItemCounts: catalog.sectionItemCounts
        )
    }

    private var filteredModelGroups: [ModelMenuGroup] {
        modelCatalog.regularGroups
    }

    private var resolvedFavoriteModels: [ModelPickerModelItem] {
        modelCatalog.favorites
    }

    private func visibleModels(in group: ModelMenuGroup) -> [SessionConfigSelectOption] {
        modelCatalog.regularModels(in: group)
    }

    private var modelCatalog: ModelPickerCatalog {
        ModelPickerCatalog(
            groups: modelGroups,
            favoriteIDs: favoriteModelIDs,
            query: normalizedModelSearch
        )
    }

    private func favorite(_ model: SessionConfigSelectOption, in group: ModelMenuGroup) {
        let favorite = ModelPickerFavorite(model: model, group: group)
        guard !favoriteModelIDs.contains(favorite) else { return }
        clearModelHighlight()
        favoriteModelIDs = favoriteModelIDs + [favorite]
    }

    private func unfavorite(_ favorite: ModelPickerFavorite) {
        clearModelHighlight()
        favoriteModelIDs = favoriteModelIDs.filter { $0 != favorite }
    }

    private func clearModelHighlight() {
        hoverTarget = nil
        keyboardTarget = nil
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
