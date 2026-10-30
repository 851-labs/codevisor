import Foundation

struct ComposerHarnessDefaults: Codable, Sendable, Equatable {
  private static let legacyModelOptionId = "model"

  var values: [String: String] = [:]
  var valuesByModel: [String: [String: String]] = [:]

  init() {}

  init(legacySelections: [String: String]) {
    let selections = legacySelections.filter { !$0.value.isEmpty }
    let modelOptionId = selections[Self.legacyModelOptionId] == nil ? nil : Self.legacyModelOptionId
    remember(selections, modelOptionId: modelOptionId)
  }

  func values(forModel model: String?) -> [String: String] {
    guard let model else { return values }
    return valuesByModel[model] ?? [:]
  }

  mutating func remember(_ configValues: [String: String], modelOptionId: String?) {
    guard let modelOptionId else {
      values.merge(configValues) { _, latest in latest }
      return
    }
    guard let model = configValues[modelOptionId] else { return }

    values = [modelOptionId: model]
    valuesByModel[model, default: [:]].merge(configValues) { _, latest in latest }
  }

  mutating func fillGaps(from older: Self) {
    values.merge(older.values) { kept, _ in kept }
    valuesByModel.merge(older.valuesByModel) { kept, olderSettings in
      kept.merging(olderSettings) { keptValue, _ in keptValue }
    }
  }
}
