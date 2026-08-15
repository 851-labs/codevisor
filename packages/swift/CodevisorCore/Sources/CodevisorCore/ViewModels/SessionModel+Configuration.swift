import Foundation
import ACPKit

extension SessionModel {
    /// Config options of a given category (e.g. model, thought_level, mode).
    public func configOptions(category: String) -> [SessionConfigOption] {
        configOptions.filter { $0.category == category }
    }

    /// Replaces the draft composer's options with a freshly inspected harness
    /// snapshot. Authentication and profile changes can alter the models a
    /// provider exposes before the first prompt creates a runtime session.
    public func replaceConfigOptions(_ options: [SessionConfigOption]) {
        configOptions = options
    }

    /// Applies capability metadata from a runtime connect that finished after
    /// history was already painted. The model is constructed from cached
    /// capabilities so the transcript can render before the agent process is
    /// up; a resumed thread's live runtime can expose a different current
    /// model, effort list, or mode set than the cache, so the authoritative
    /// snapshot replaces it here. Later `configOptionUpdate` /
    /// `currentModeUpdate` stream events still win — they arrive after this
    /// and overwrite as usual.
    public func applyRuntimeMetadata(
        modeState: SessionModeState?,
        configOptions: [SessionConfigOption]
    ) {
        if let modeState { self.modeState = modeState }
        if !configOptions.isEmpty { self.configOptions = configOptions }
    }

    /// Sets a config option optimistically, then asks the server to persist it.
    /// Runtime config-update events remain authoritative for dependent options
    /// (a model change can replace the available effort and speed lists).
    @discardableResult
    public func setConfigOption(configId: String, value: String) async -> Bool {
        let revision = (configMutationRevisions[configId] ?? 0) &+ 1
        configMutationRevisions[configId] = revision
        let previousValue: String?
        if let index = configOptions.firstIndex(where: { $0.id == configId }) {
            previousValue = configOptions[index].currentValue
            configOptions[index].currentValue = value
        } else {
            previousValue = nil
        }

        do {
            try await transport.setConfigOption(configId: configId, value: value)
            return true
        } catch {
            // Only undo this mutation if it is still the newest request and
            // the live config stream has not already supplied another value.
            if configMutationRevisions[configId] == revision,
                let previousValue,
                let index = configOptions.firstIndex(where: { $0.id == configId }),
                configOptions[index].currentValue == value
            {
                configOptions[index].currentValue = previousValue
            }
            errorMessage = serverErrorMessage(error)
            return false
        }
    }
}
