import ACPKit

extension SessionController {
  /// Viewing a transcript only loads saved state. Runtime selections are
  /// applied when the user submits work, immediately before the prompt or goal.
  func applyPendingRuntimeConfiguration(to model: SessionModel) async {
    guard let harnessId = connectedHarnessId ?? selectedHarnessId else { return }
    if let pendingModeId {
      await model.setMode(pendingModeId)
    }
    pendingModeId = nil

    // Model changes can replace the model-specific thinking and speed
    // options. Apply dependent selections afterward so a remembered fast
    // tier is available by the time it is restored.
    let pendingConfig = pendingConfigByHarness[harnessId] ?? [:]
    let optionCategories = Dictionary(
      uniqueKeysWithValues: model.configOptions.map { ($0.id, $0.category ?? "") }
    )
    let categoryOrder = [
      SessionConfigOption.Category.model: 0,
      SessionConfigOption.Category.thoughtLevel: 1,
      SessionConfigOption.Category.speed: 2,
    ]
    // Cached options can disappear after an agent update or a model
    // change. Never replay a stale selection the runtime no longer
    // advertises (especially a hidden model-specific control).
    let supportedPendingConfig = pendingConfig.filter { optionCategories[$0.key] != nil }
    let orderedPendingConfig = supportedPendingConfig.sorted { left, right in
      func priority(_ configId: String) -> Int {
        if configId == "model" { return 0 }
        if configId == "speed" { return 2 }
        return categoryOrder[optionCategories[configId] ?? ""] ?? 99
      }
      let leftPriority = priority(left.key)
      let rightPriority = priority(right.key)
      if leftPriority == rightPriority { return left.key < right.key }
      return leftPriority < rightPriority
    }
    for (configId, value) in orderedPendingConfig {
      await model.setConfigOption(configId: configId, value: value)
    }
    pendingConfigByHarness[harnessId] = nil
  }
}
