import Foundation
import ACPKit

extension SessionModel {
  /// Config options of a given category (e.g. model, thought_level, mode).
  public func configOptions(category: String) -> [SessionConfigOption] {
    configOptions.filter { $0.category == category }
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
    if !configOptions.isEmpty { self.configOptions = preservingInFlightPicks(configOptions) }
  }

  /// A runtime snapshot produced before an in-flight pick reached the
  /// server still carries the previous value; keep the user's pick until
  /// its own request settles. Everything else in the snapshot applies.
  func preservingInFlightPicks(_ options: [SessionConfigOption]) -> [SessionConfigOption] {
    guard !inFlightConfigValues.isEmpty else { return options }
    return options.map { option in
      guard let value = inFlightConfigValues[option.id] else { return option }
      var updated = option
      updated.currentValue = value
      return updated
    }
  }

  /// Sets a config option optimistically, then asks the server to persist it.
  /// Runtime config-update events remain authoritative for dependent options
  /// (a model change can replace the available effort and speed lists).
  @discardableResult
  public func setConfigOption(configId: String, value: String) async -> Bool {
    let revision = (configMutationRevisions[configId] ?? 0) &+ 1
    configMutationRevisions[configId] = revision
    inFlightConfigValues[configId] = value
    defer {
      if configMutationRevisions[configId] == revision {
        inFlightConfigValues[configId] = nil
      }
    }
    let previousValue: String?
    if let index = configOptions.firstIndex(where: { $0.id == configId }) {
      previousValue = configOptions[index].currentValue
      configOptions[index].currentValue = value
    } else {
      previousValue = nil
    }

    do {
      let resolved = try await transport.setConfigOption(configId: configId, value: value)
      if configMutationRevisions[configId] == revision, let resolved, !resolved.isEmpty {
        configOptions = resolved
      }
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
