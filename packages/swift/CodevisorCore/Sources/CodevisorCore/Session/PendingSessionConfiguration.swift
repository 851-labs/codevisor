import ACPKit
import Observation

/// Owns selections awaiting a runtime, including picks made during an apply.
/// A completed request clears only the value it sent, preserving newer picks.
@MainActor
@Observable
final class PendingSessionConfiguration {
  private(set) var valuesByHarness: [String: [String: String]] = [:] {
    didSet { onChange() }
  }
  private(set) var modeId: String? { didSet { onChange() } }
  @ObservationIgnored private let currentHarness: () -> String?
  @ObservationIgnored private let fallbackOptions: () -> [SessionConfigOption]
  @ObservationIgnored private let onChange: () -> Void

  init(
    currentHarness: @escaping () -> String?,
    fallbackOptions: @escaping () -> [SessionConfigOption],
    onChange: @escaping () -> Void
  ) {
    self.currentHarness = currentHarness
    self.fallbackOptions = fallbackOptions
    self.onChange = onChange
  }

  func values(for harnessId: String) -> [String: String]? {
    valuesByHarness[harnessId]
  }

  func value(for configId: String, in harnessId: String) -> String? {
    valuesByHarness[harnessId]?[configId]
  }

  func restoreValues(_ values: [String: [String: String]]) {
    valuesByHarness = values
  }

  func replaceValues(_ values: [String: String]?, for harnessId: String) {
    valuesByHarness[harnessId] = values
  }

  func stage(_ value: String, for configId: String, in harnessId: String) {
    valuesByHarness[harnessId, default: [:]][configId] = value
  }

  func removeValue(for configId: String, in harnessId: String) {
    valuesByHarness[harnessId]?[configId] = nil
  }

  func clearAppliedValue(_ value: String, for configId: String, in harnessId: String) {
    if valuesByHarness[harnessId]?[configId] == value {
      removeValue(for: configId, in: harnessId)
    }
  }

  func mergeDefaults(_ values: [String: String], for harnessId: String) {
    valuesByHarness[harnessId, default: [:]].merge(values) { current, _ in current }
  }

  func setMode(_ modeId: String?) {
    self.modeId = modeId
  }

  /// Viewing a transcript only loads saved state. Runtime selections are
  /// applied when the user submits work, immediately before the prompt or goal.
  ///
  /// Picks can land while this runs (the composer stays interactive). Each
  /// key is re-read right before it is applied, and a key is cleared only
  /// when its staged value is still the one that was applied, so a newer
  /// pick is never dropped: it is applied by a later pass.
  func apply(to model: SessionModel) async {
    guard let harnessId = currentHarness() else { return }
    if let modeId {
      await model.setMode(modeId)
    }
    modeId = nil

    // Bounded: each pass only repeats for picks made during the previous.
    for _ in 0..<4 {
      let appliedAny = await applyPendingConfigurationPass(to: model, harnessId: harnessId)
      guard appliedAny else { break }
    }
  }

  /// Applies every currently staged value once. Returns whether any value
  /// was sent to the runtime.
  private func applyPendingConfigurationPass(
    to model: SessionModel,
    harnessId: String
  ) async -> Bool {
    let pendingConfig = valuesByHarness[harnessId] ?? [:]
    guard !pendingConfig.isEmpty else { return false }
    let runtimeCategories = Dictionary(
      model.configOptions.map { ($0.id, $0.category ?? "") }
    ) { first, _ in first }
    // Until the runtime reports options, order by the definitions this
    // composer showed.
    let optionCategories =
      runtimeCategories.isEmpty
      ? Dictionary(fallbackOptions().map { ($0.id, $0.category ?? "") }) { first, _ in first }
      : runtimeCategories
    // A runtime that has not reported its options yet cannot reject
    // anything; otherwise never replay a stale selection the runtime no
    // longer advertises (especially a hidden model-specific control).
    let supportedPendingConfig = pendingConfig.filter {
      !$0.value.isEmpty && (runtimeCategories.isEmpty || runtimeCategories[$0.key] != nil)
    }
    // Model changes can replace the model-specific thinking and speed
    // options. Apply dependent selections afterward so a remembered fast
    // tier is available by the time it is restored.
    let categoryOrder = [
      SessionConfigOption.Category.model: 0,
      SessionConfigOption.Category.thoughtLevel: 1,
      SessionConfigOption.Category.speed: 2,
    ]
    func priority(_ configId: String) -> Int {
      if configId == "model" { return 0 }
      if configId == "speed" { return 2 }
      return categoryOrder[optionCategories[configId] ?? ""] ?? 99
    }
    let orderedKeys = supportedPendingConfig.keys.sorted { left, right in
      let leftPriority = priority(left)
      let rightPriority = priority(right)
      if leftPriority == rightPriority { return left < right }
      return leftPriority < rightPriority
    }
    var appliedAny = false
    for configId in orderedKeys {
      // A pick made while an earlier key was applying may have replaced
      // or already applied this one.
      guard let value = valuesByHarness[harnessId]?[configId], !value.isEmpty else {
        continue
      }
      appliedAny = true
      await model.setConfigOption(configId: configId, value: value)
      clearAppliedValue(value, for: configId, in: harnessId)
    }
    // Drop what the runtime cannot apply, keeping anything newer.
    for (configId, value) in pendingConfig where supportedPendingConfig[configId] == nil {
      clearAppliedValue(value, for: configId, in: harnessId)
    }
    if valuesByHarness[harnessId]?.isEmpty == true {
      valuesByHarness[harnessId] = nil
    }
    return appliedAny
  }
}
