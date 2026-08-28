import Foundation
import ACPKit

extension SessionController {
    public func draftSnapshot() -> ComposerDraftStore.Draft {
        ComposerDraftStore.Draft(
            projectId: project.id,
            projectServerId: project.serverId,
            composerText: composerText,
            attachments: composerAttachments.compactMap {
                guard $0.state != .loading else { return nil }
                return ComposerDraftStore.DraftAttachment(
                    id: $0.id,
                    name: $0.name,
                    mimeType: $0.mimeType,
                    kind: $0.kind.rawValue,
                    localData: $0.localData
                )
            },
            selectedHarnessId: selectedHarnessId,
            configByHarness: pendingConfigByHarness,
            modeId: pendingModeId,
            isGoalComposerArmed: isGoalComposerArmed,
            isGoalEditing: isGoalEditing,
            composerTextBeforeGoalEdit: composerTextBeforeGoalEdit,
            usesImmediateDefaultsPersistence: true,
            selectionWasAutomaticallyCarried: automaticSelectionIntent != nil
        )
    }

    public func restoreDraft(_ draft: ComposerDraftStore.Draft) {
        isRestoringDraft = true
        composerText = draft.composerText
        composerAttachments = draft.attachments.map {
            ComposerAttachment(
                id: $0.id,
                name: $0.name,
                mimeType: $0.mimeType,
                kind: Attachment.Kind(rawValue: $0.kind) ?? .file,
                localData: $0.localData,
                state: .uploading
            )
        }
        selectedHarnessId = draft.selectedHarnessId
        pendingConfigByHarness = draft.configByHarness
        pendingModeId = draft.modeId
        isGoalComposerArmed = draft.isGoalComposerArmed
        isGoalEditing = draft.isGoalEditing
        composerTextBeforeGoalEdit = draft.composerTextBeforeGoalEdit
        isRestoringDraft = false

        automaticSelectionIntent =
            draft.selectionWasAutomaticallyCarried ? currentComposerSelectionIntent() : nil
        automaticSelectionNeedsResolution = automaticSelectionIntent != nil

        // Drafts written before immediate defaults persistence need one
        // compatibility promotion. Current drafts deliberately stay separate:
        // an automatically carried machine-switch selection must not become a
        // machine default merely because the app relaunched.
        if !draft.usesImmediateDefaultsPersistence, let composerDefaults {
            for (harnessId, configValues) in draft.configByHarness {
                composerDefaults.rememberConfigSelections(
                    in: resolvedComposerDefaultsScope,
                    harnessId: harnessId,
                    configValues: configValues
                )
            }
            composerDefaults.rememberHarnessSelection(
                in: resolvedComposerDefaultsScope,
                harnessId: draft.selectedHarnessId
            )
        }

        // Server file ids are not assumed to survive indefinitely. Re-upload
        // the persisted local bytes and produce fresh refs for the next send.
        for attachment in composerAttachments { startUpload(attachment) }
    }

    func draftDidChange() {
        guard !isRestoringDraft, isDraft, let onDraftChange else { return }
        onDraftChange(draftSnapshot())
    }

    // MARK: - Remembered composer defaults

    /// True until the first send creates the real session — the window where
    /// remembered defaults are seeded into pending config.
    private var isDraft: Bool { serverSession == nil && !hasSentFirst }

    /// Eagerly-created workspace chat records still behave like drafts until
    /// their first agent session exists. They need inherited configuration
    /// even though `serverSession` is already non-nil.
    var acceptsNewChatDefaults: Bool {
        !hasSentFirst
            && resumeAgentSessionId?.isEmpty != false
            && serverSession?.agentSessionId?.isEmpty != false
    }

    var resolvedComposerDefaultsScope: ComposerDefaultsStore.Scope {
        composerDefaultsScope ?? .newWorkspace(serverId: project.serverId)
    }

    /// Seeds a new-chat draft from the last explicit selections on this
    /// machine. Called once by `SessionStore` when a draft is made.
    public func applyComposerDefaults() {
        guard let composerDefaults, acceptsNewChatDefaults else { return }
        if let harnessId = composerDefaults.lastHarnessId(for: resolvedComposerDefaultsScope),
            !harnessId.isEmpty,
            harnesses.isEmpty || harnesses.contains(where: { $0.id == harnessId })
        {
            selectedHarnessId = harnessId
        }
        seedRememberedConfig()
    }

    /// Captures portable selection values before a machine switch. Capability
    /// definitions never cross machines; the destination validates these ids
    /// and values against its own catalog.
    func currentComposerSelectionIntent() -> ComposerSelectionIntent? {
        guard let harnessId = selectedHarnessId, !harnessId.isEmpty else { return nil }
        var configValues = rememberedConfigValues
        configValues.merge(pendingConfigByHarness[harnessId] ?? [:]) { _, pending in pending }
        let selectedModel = Self.modelOption(in: configOptions)
        if let selectedModel {
            configValues[selectedModel.id] = selectedModel.currentValue
        }
        return ComposerSelectionIntent(
            harnessId: harnessId,
            configValues: configValues,
            modelValue: selectedModel?.currentValue ?? configValues["model"]
        )
    }

    /// Resolves the selected harness whenever a fresh destination catalog is
    /// applied. A compatible outgoing harness/model wins; otherwise the
    /// destination machine's durable profile wins; the catalog's first harness
    /// is only the final fallback.
    func applyNewChatSelectionPolicy(_ capabilities: [ServerHarnessCapability]) {
        let availableIds = Set(capabilities.map(\.harness.id))
        if let intent = automaticSelectionIntent,
            let capability = capabilities.first(where: { $0.harness.id == intent.harnessId }),
            canCarry(intent, to: capability)
        {
            selectedHarnessId = intent.harnessId
            var carried = intent.configValues
            if let modelValue = intent.modelValue,
                let model = Self.modelOption(in: capability.configOptions)
            {
                carried[model.id] = modelValue
            }
            pendingConfigByHarness[intent.harnessId] = carried
            // Add destination-only remembered values (for example a speed
            // tier absent from the source snapshot) without replacing carried
            // values. The live resolver validates the complete set below.
            seedRememberedConfig()
            automaticSelectionNeedsResolution = true
            return
        }

        if let intent = automaticSelectionIntent {
            pendingConfigByHarness[intent.harnessId] = nil
            clearAutomaticSelection()
            applyDestinationMachineDefaults(availableHarnessIds: availableIds)
            return
        }

        if let selectedHarnessId, availableIds.contains(selectedHarnessId) {
            seedRememberedConfig()
            return
        }
        applyDestinationMachineDefaults(availableHarnessIds: availableIds)
    }

    func applyDestinationMachineDefaults(availableHarnessIds: Set<String>? = nil) {
        let availableIds = availableHarnessIds ?? Set(harnesses.map(\.id))
        let rememberedHarness = composerDefaults?.lastHarnessId(for: resolvedComposerDefaultsScope)
        if let rememberedHarness, availableIds.contains(rememberedHarness) {
            selectedHarnessId = rememberedHarness
        } else {
            selectedHarnessId = harnesses.first(where: { availableIds.contains($0.id) })?.id
        }
        seedRememberedConfig()
    }

    func clearAutomaticSelection() {
        automaticSelectionIntent = nil
        automaticSelectionNeedsResolution = false
    }

    private func canCarry(
        _ intent: ComposerSelectionIntent,
        to capability: ServerHarnessCapability
    ) -> Bool {
        guard let modelValue = intent.modelValue else { return true }
        guard let model = Self.modelOption(in: capability.configOptions) else { return false }
        return model.options.contains { $0.value == modelValue }
    }

    static func modelOption(in options: [SessionConfigOption]) -> SessionConfigOption? {
        options.first {
            ($0.category == SessionConfigOption.Category.model || $0.id == "model")
                && !$0.options.isEmpty
        }
    }

    /// Stages the remembered config selections for the selected harness as
    /// pending edits so the pickers show them and the agent applies them on
    /// connect. Values are validated against the known option lists when
    /// available; unknown lists trust the stored values and let the live
    /// agent correct them.
    func seedRememberedConfig() {
        guard let composerDefaults, let harnessId = selectedHarnessId else { return }
        let remembered = composerDefaults.configSelections(
            forHarness: harnessId,
            in: resolvedComposerDefaultsScope
        )
        guard !remembered.isEmpty else { return }
        var options =
            configOptionsByHarness[harnessId]
            ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
        guard !options.isEmpty else {
            pendingConfigByHarness[harnessId, default: [:]].merge(remembered) { current, _ in current }
            return
        }
        for (configId, value) in remembered {
            // A speed option can be absent until its remembered model is
            // restored. Keep it queued and validate it against the live agent
            // after the model change makes the option available.
            guard let index = options.firstIndex(where: { $0.id == configId }) else {
                if configId == "speed" {
                    pendingConfigByHarness[harnessId, default: [:]][configId] = value
                }
                continue
            }
            guard options[index].options.contains(where: { $0.value == value }) else { continue }
            let selectedValue = pendingConfigByHarness[harnessId]?[configId] ?? value
            pendingConfigByHarness[harnessId, default: [:]][configId] = selectedValue
            options[index].currentValue = selectedValue
        }
        configOptionsByHarness[harnessId] = options
    }

    /// Remembered config categories (model, reasoning, speed, model config)
    /// as currently selected — what composer memory captures.
    var rememberedConfigValues: [String: String] {
        let values =
            configOptions
            .filter { Self.rememberedConfigCategories.contains($0.category ?? "") }
            .map { ($0.id, $0.currentValue) }
        return Dictionary(values) { _, last in last }
    }

    /// Captures this chat as the inheritance source for its scope. Workspace
    /// capture replaces the selected harness snapshot so values from a
    /// previously focused sibling cannot leak into the next chat.
    public func rememberCurrentComposerConfiguration() {
        guard let composerDefaults,
            let harnessId = connectedHarnessId ?? selectedHarnessId ?? serverSession?.harnessId,
            !harnessId.isEmpty
        else { return }
        switch resolvedComposerDefaultsScope {
        case let .newWorkspace(serverId):
            composerDefaults.rememberHarnessSelection(
                in: .newWorkspace(serverId: serverId),
                harnessId: harnessId
            )
            composerDefaults.rememberConfigSelections(
                in: .newWorkspace(serverId: serverId),
                harnessId: harnessId,
                configValues: rememberedConfigValues
            )
        case let .workspace(id, serverId):
            composerDefaults.rememberFocusedChat(
                workspaceId: id,
                serverId: serverId,
                harnessId: harnessId,
                configValues: rememberedConfigValues
            )
        }
    }

    /// A standalone draft becomes the first chat of a concrete workspace
    /// before its agent is connected. Snapshot its selected configuration
    /// into that workspace immediately so a sibling tab opened during setup
    /// inherits the same values.
    public func moveComposerDefaults(to scope: ComposerDefaultsStore.Scope) {
        composerDefaultsScope = scope
        rememberCurrentComposerConfiguration()
    }
}
