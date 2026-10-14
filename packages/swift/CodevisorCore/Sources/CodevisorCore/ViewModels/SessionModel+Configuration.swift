import Foundation
import ACPKit

extension SessionModel {
  public func configOptions(category: String) -> [SessionConfigOption] {
    configOptions.filter { $0.category == category }
  }

  public func applyRuntimeMetadata(
    modeState: SessionModeState?,
    configOptions: [SessionConfigOption]
  ) {
    if let modeState { self.modeState = modeState }
    if !configOptions.isEmpty { self.configOptions = preservingInFlightPicks(configOptions) }
  }

  func preservingInFlightPicks(_ options: [SessionConfigOption]) -> [SessionConfigOption] {
    guard !inFlightConfigValues.isEmpty else { return options }
    return options.map { option in
      guard let value = inFlightConfigValues[option.id] else { return option }
      var updated = option
      updated.currentValue = value
      return updated
    }
  }

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
