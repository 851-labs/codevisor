import Foundation
import ACPKit

extension SessionController {
    /// Adopts server changes that affect this controller's runtime while
    /// ignoring presentation-only metadata (title, attention, unread state,
    /// and timestamps). Session list events replace the complete
    /// `ChatSession`, so comparing the whole value would re-publish this
    /// observed property for every remote attention update.
    @discardableResult
    public func reconcileExistingSession(_ session: ChatSession) -> Bool {
        guard serverSession.map(ExistingSessionRuntimeState.init) != ExistingSessionRuntimeState(session)
        else { return false }
        configureExistingSession(session)
        return true
    }

    /// Binds a persisted chat to this controller and paints its last accepted
    /// selections over cached option definitions. The values remain
    /// provisional until the live session reconnect validates them.
    public func configureExistingSession(_ session: ChatSession) {
        let identityChanged =
            serverSession?.id != session.id
            || resumeAgentSessionId != session.agentSessionId
        serverSession = session
        resumeAgentSessionId = session.agentSessionId
        if !session.harnessId.isEmpty {
            selectedHarnessId = session.harnessId
        }
        guard model == nil else { return }
        seedExistingSessionConfiguration(from: session)
        // An in-flight connect owns the validation state machine: a refresh
        // snapshot arriving mid-connect usually carries the agent session id
        // that this very connect just minted server-side (`session.updated`
        // from `ensureAgentSessionFor`). Resetting to `.connecting` here would
        // wedge the composer forever — nothing on the send path recomputes the
        // state after the model is published. The id itself was still adopted
        // above; the connect settles the flags when it completes.
        guard identityChanged, session.agentSessionId?.isEmpty == false, !isConnecting else { return }
        didLoadExistingHarnessCapabilities = false
        didFinishExistingRuntimeConfiguration = false
        didLoadExistingRuntimeConfiguration = false
        existingConfigurationError = nil
        configurationAdjustmentMessage = nil
        configurationValidationState = .connecting
        isLoadingInitialHistory = true
        initialHistoryLoadStartedAt = ProcessInfo.processInfo.systemUptime
    }

    private func seedExistingSessionConfiguration(from session: ChatSession? = nil) {
        let session = session ?? serverSession
        guard model == nil,
            let session,
            !session.harnessId.isEmpty,
            let selections = session.configSelections,
            !selections.isEmpty
        else { return }
        var options =
            configOptionsByHarness[session.harnessId]
            ?? configCache.options(forHarness: session.harnessId, onServer: project.serverId)
        for (configId, value) in selections {
            if let index = options.firstIndex(where: { $0.id == configId }) {
                // Keep even a now-unknown value visible while validation runs;
                // SessionConfigOption.currentName falls back to the raw value.
                options[index].currentValue = value
            } else {
                // The value snapshot is enough to paint a disabled provisional
                // picker even when this machine has no cached definitions yet.
                options.append(Self.provisionalConfigOption(id: configId, value: value))
            }
        }
        configOptionsByHarness[session.harnessId] = options
    }

    private static func provisionalConfigOption(id: String, value: String) -> SessionConfigOption {
        let normalized = id.lowercased()
        let category: String? =
            if normalized == "model" {
                SessionConfigOption.Category.model
            } else if normalized.contains("reason")
                || normalized.contains("effort")
                || normalized.contains("thinking")
            {
                SessionConfigOption.Category.thoughtLevel
            } else if normalized.contains("speed") {
                SessionConfigOption.Category.speed
            } else {
                SessionConfigOption.Category.modelConfig
            }
        return SessionConfigOption(
            id: id,
            name: id.replacingOccurrences(of: "_", with: " ").capitalized,
            category: category,
            currentValue: value,
            options: [SessionConfigSelectOption(value: value, name: value)]
        )
    }

    var hasExistingAgentSession: Bool {
        resumeAgentSessionId?.isEmpty == false
            || serverSession?.agentSessionId?.isEmpty == false
    }

    public var isConnectingToHarness: Bool {
        configurationValidationState == .connecting
    }

    public var configurationValidationError: String? {
        guard case let .failed(message) = configurationValidationState else { return nil }
        return message
    }

    func updateConfigurationValidationState() {
        guard hasExistingAgentSession else {
            configurationValidationState = .ready
            return
        }
        if didLoadExistingRuntimeConfiguration
            || (didFinishExistingRuntimeConfiguration && didLoadExistingHarnessCapabilities)
        {
            configurationValidationState = .ready
        } else if didFinishExistingRuntimeConfiguration,
            let existingConfigurationError
        {
            configurationValidationState = .failed(existingConfigurationError)
        } else {
            configurationValidationState = .connecting
        }
    }

    /// Selectable config options: live when connected, otherwise the cached
    /// (stale) options for the selected harness with any pending edits applied.
    public var configOptions: [SessionConfigOption] {
        if let model, !model.configOptions.isEmpty || !isConnectingToHarness {
            return model.configOptions
        }
        guard let harnessId = selectedHarnessId else { return [] }
        let pendingConfig = pendingConfigByHarness[harnessId] ?? [:]
        return
            (configOptionsByHarness[harnessId]
            ?? configCache.options(forHarness: harnessId, onServer: project.serverId)).map { option in
                guard let pending = pendingConfig[option.id] else { return option }
                var updated = option
                updated.currentValue = pending
                return updated
            }
    }

    /// Categories folded into the combined model dropdown rather than shown
    /// as individual picker chips.
    private static let modelMenuCategories: Set<String> = [
        SessionConfigOption.Category.model,
        SessionConfigOption.Category.thoughtLevel,
        SessionConfigOption.Category.speed,
    ]

    /// Config categories that follow the user between composers. Modes remain
    /// local to a chat; run location is remembered separately from harness
    /// configuration.
    static let rememberedConfigCategories: Set<String> = [
        SessionConfigOption.Category.model,
        SessionConfigOption.Category.thoughtLevel,
        SessionConfigOption.Category.speed,
        SessionConfigOption.Category.modelConfig,
    ]

    /// A draft never sits with an empty model chip: when the harness
    /// reports selectable models but no usable current choice — and nothing
    /// is pending or remembered — the first option becomes the pending
    /// selection, which is exactly what the send would use.
    func ensureDefaultModelSelection() {
        guard model == nil, let harnessId = selectedHarnessId, let option = modelOption
        else { return }
        let isValid = option.options.contains { $0.value == option.currentValue }
        guard !isValid, let first = option.options.first else { return }
        var pending = pendingConfigByHarness[harnessId] ?? [:]
        guard pending[option.id] == nil else { return }
        pending[option.id] = first.value
        pendingConfigByHarness[harnessId] = pending
    }

    /// The model choice shown in the combined model dropdown.
    public var modelOption: SessionConfigOption? {
        configOptions.first { $0.category == SessionConfigOption.Category.model && !$0.options.isEmpty }
    }

    /// Thinking/reasoning controls shown in the combined model dropdown.
    /// Some agents expose more than one (for example, Thinking plus Effort).
    public var thoughtLevelOptions: [SessionConfigOption] {
        configOptions.filter { $0.category == SessionConfigOption.Category.thoughtLevel && !$0.options.isEmpty }
    }

    /// The speed (standard/fast) shown in the combined model dropdown; only
    /// present when the agent/model pair supports a fast tier.
    public var speedOption: SessionConfigOption? {
        configOptions.first { $0.category == SessionConfigOption.Category.speed && !$0.options.isEmpty }
    }

    public var hasModelMenu: Bool {
        modelOption != nil || !thoughtLevelOptions.isEmpty || speedOption != nil
    }

    /// Resumed chats intentionally avoid painting generic fresh-session
    /// defaults while their runtime metadata loads. Reserve the model picker's
    /// place with a spinner during that gap instead of popping it in later.
    public var isLoadingModelMenu: Bool {
        guard !hasModelMenu else { return false }
        // A background revalidation is stale-while-revalidate like every
        // other catalog consumer: only spin when there is NO settled answer
        // at all. A draft whose machine has nothing usable but a known
        // sign-in-required list holds its "Select a harness" chip steady
        // instead of flickering on every sync-driven refresh.
        if isRefreshingHarnessCapabilities { return !hasSettledCatalogKnowledge }
        if isConnecting || isConnectingToHarness { return true }
        // A draft with no spawned agent yet (new-chat page, deferred chats)
        // fetching harness capabilities: hold the model chip's slot with a
        // spinner too, instead of rendering nothing until options land.
        // Scoped to agent-less drafts so a connected harness that simply has
        // no model options can't spin forever on a stale preparation state.
        if serverSession?.agentSessionId?.isEmpty != false, model == nil,
            preparationState == .loading
        {
            return true
        }
        guard model == nil, serverSession?.agentSessionId?.isEmpty == false else { return false }
        if case .failed = status { return false }
        return true
    }

    /// The config options still shown as individual picker chips (model
    /// config, unknown categories), in a sensible order. Mode options are
    /// excluded entirely: the composer's plan toggle is the only mode control
    /// (everything else runs in the harness's full-access/build default).
    public var pickerOptions: [SessionConfigOption] {
        let order = [SessionConfigOption.Category.modelConfig]
        return
            configOptions
            .filter { option in
                !option.options.isEmpty
                    && !Self.modelMenuCategories.contains(option.category ?? "")
                    && option.category != SessionConfigOption.Category.mode
                    && option.id != "mode"
            }
            .sorted { left, right in
                let leftIndex = order.firstIndex(of: left.category ?? "") ?? 99
                let rightIndex = order.firstIndex(of: right.category ?? "") ?? 99
                if leftIndex == rightIndex { return left.name < right.name }
                return leftIndex < rightIndex
            }
    }

    public func setConfigOption(_ configId: String, _ value: String) async {
        guard !isConnectingToHarness else { return }
        let optionBeforeChange = configOptions.first { $0.id == configId }
        let previousValue = optionBeforeChange?.currentValue
        let changesModel =
            optionBeforeChange?.category == SessionConfigOption.Category.model
            || configId == "model"
        let modelResolutionRevision: UInt64? =
            if changesModel, previousValue != value {
                beginModelConfigurationResolution()
            } else {
                nil
            }
        defer {
            if let modelResolutionRevision {
                finishModelConfigurationResolution(modelResolutionRevision)
            }
        }
        var accepted = true
        if let model {
            accepted = await model.setConfigOption(configId: configId, value: value)
            if let harnessId = connectedHarnessId {
                configCache.store(model.configOptions, forHarness: harnessId, onServer: project.serverId)
                configOptionsByHarness[harnessId] = model.configOptions
            }
        } else {
            // Not connected yet: remember it and apply on connect.
            if let harnessId = selectedHarnessId {
                pendingConfigByHarness[harnessId, default: [:]][configId] = value
                var options =
                    configOptionsByHarness[harnessId]
                    ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
                if let index = options.firstIndex(where: { $0.id == configId }) {
                    options[index].currentValue = value
                    configOptionsByHarness[harnessId] = options
                }
                if let modelResolutionRevision {
                    accepted = await resolveDraftConfiguration(
                        harnessId: harnessId,
                        expectedModelValue: value,
                        revision: modelResolutionRevision
                    )
                }
            }
        }
        if accepted,
            optionBeforeChange?.category == SessionConfigOption.Category.model,
            previousValue != value
        {
            captureModelSelected(modelId: value, previousModelId: previousValue)
            configurationAdjustmentMessage = nil
            // The user just chose a model, so a "we swapped your model" notice
            // no longer describes the current state.
            model?.clearModelFallback()
        }
        // Explicit picker actions become the next composer's defaults
        // immediately, including in an unsent draft. Persist the resulting
        // authoritative option set so model-dependent effort/speed resets are
        // remembered too.
        if accepted,
            Self.rememberedConfigCategories.contains(optionBeforeChange?.category ?? ""),
            let harnessId = connectedHarnessId ?? selectedHarnessId
        {
            composerDefaults?.rememberConfigSelections(
                in: resolvedComposerDefaultsScope,
                harnessId: harnessId,
                configValues: rememberedConfigValues
            )
            composerDefaults?.rememberHarnessSelection(
                in: resolvedComposerDefaultsScope,
                harnessId: harnessId
            )
        }
    }

    public func dismissConfigurationAdjustment() {
        configurationAdjustmentMessage = nil
    }

    private func beginModelConfigurationResolution() -> UInt64 {
        modelConfigurationResolutionRevision &+= 1
        isResolvingModelConfiguration = true
        return modelConfigurationResolutionRevision
    }

    private func finishModelConfigurationResolution(_ revision: UInt64) {
        guard modelConfigurationResolutionRevision == revision else { return }
        isResolvingModelConfiguration = false
    }

    /// A draft has no durable runtime to ask when its model changes. Resolve
    /// the same configuration against a temporary harness inspection so new
    /// chat and resumed chat expose identical model-dependent controls.
    private func resolveDraftConfiguration(
        harnessId: String,
        expectedModelValue: String,
        revision: UInt64
    ) async -> Bool {
        guard let serverClient else { return true }
        let cacheRevision = configCache.capabilityRevision(forServer: project.serverId)
        var selections = Dictionary(
            uniqueKeysWithValues: configOptions.map { ($0.id, $0.currentValue) }
        )
        selections.merge(pendingConfigByHarness[harnessId] ?? [:]) { _, pending in pending }
        selections["model"] = expectedModelValue
        do {
            let response = try await serverClient.capabilities(
                cwd: project.folderURL.path,
                harnessId: harnessId,
                configSelections: selections
            )
            guard modelConfigurationResolutionRevision == revision,
                pendingConfigByHarness[harnessId]?["model"] == expectedModelValue,
                cacheRevision == configCache.capabilityRevision(forServer: project.serverId),
                let capability = response.harnesses.first(where: { $0.harness.id == harnessId }),
                !capability.configOptions.isEmpty
            else { return true }

            guard
                configCache.store(
                    capability,
                    forServer: project.serverId,
                    ifRevision: cacheRevision
                )
            else { return true }
            configOptionsByHarness[harnessId] = capability.configOptions
            pendingConfigByHarness[harnessId] = Dictionary(
                uniqueKeysWithValues: capability.configOptions.map { ($0.id, $0.currentValue) }
            )
            return capability.configOptions.first {
                $0.category == SessionConfigOption.Category.model || $0.id == "model"
            }?.currentValue == expectedModelValue
        } catch {
            // Keep the optimistic draft selection queued. First connection
            // remains the final validator if this best-effort inspection fails.
            return true
        }
    }
}

/// The subset of a server session consumed by `SessionController`. Sidebar
/// and attention metadata is rendered from `ProjectListModel`, not from the
/// controller's retained session snapshot.
private struct ExistingSessionRuntimeState: Equatable {
    let id: UUID
    let projectId: UUID
    let serverId: String
    let harnessId: String
    let harnessAccountId: String?
    let agentSessionId: String?
    let worktreeName: String?
    let cwd: String?
    let configSelections: [String: String]?

    init(_ session: ChatSession) {
        id = session.id
        projectId = session.projectId
        serverId = session.serverId
        harnessId = session.harnessId
        harnessAccountId = session.harnessAccountId
        agentSessionId = session.agentSessionId
        worktreeName = session.worktreeName
        cwd = session.cwd
        configSelections = session.configSelections
    }
}
