import Foundation
import ACPKit

/// Projects a chat's saved values over catalog definitions until its runtime reconnects.
enum SavedSessionConfigOptions {
  static func project(
    definitions: [SessionConfigOption],
    selections: [String: String]
  ) -> [SessionConfigOption] {
    var options = selectedDefinitions(definitions, selections: selections)
    appendMissingOptions(to: &options, selections: selections)
    appendUnlistedValues(to: &options)
    return options
  }

  private static func selectedDefinitions(
    _ definitions: [SessionConfigOption],
    selections: [String: String]
  ) -> [SessionConfigOption] {
    definitions.compactMap { definition in
      var option = definition
      if let value = selections[option.id] {
        option.currentValue = value
      } else if isModelOption(option) {
        option.currentValue = ""
      } else {
        return nil
      }
      return option
    }
  }

  private static func appendMissingOptions(
    to options: inout [SessionConfigOption],
    selections: [String: String]
  ) {
    for (configId, value) in selections.sorted(by: { $0.key < $1.key })
    where !options.contains(where: { $0.id == configId }) {
      // The value snapshot is enough to paint a provisional picker
      // even when this machine has no cached definitions yet.
      options.append(provisionalConfigOption(id: configId, value: value))
    }
  }

  private static func appendUnlistedValues(to options: inout [SessionConfigOption]) {
    // Keep a saved value visible (by its raw id) when stale catalog
    // lists do not carry it; the runtime decides its availability.
    for index in options.indices {
      let value = options[index].currentValue
      if !value.isEmpty, !options[index].options.contains(where: { $0.value == value }) {
        options[index].options.append(SessionConfigSelectOption(value: value, name: value))
      }
    }
  }

  private static func provisionalConfigOption(id: String, value: String) -> SessionConfigOption {
    let normalized = id.lowercased()
    let category = provisionalCategory(normalized)
    return SessionConfigOption(
      id: id,
      name: id.replacingOccurrences(of: "_", with: " ").capitalized,
      category: category,
      currentValue: value,
      options: [SessionConfigSelectOption(value: value, name: value)]
    )
  }

  private static func provisionalCategory(_ normalized: String) -> String? {
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
  }

  static func isModelOption(_ option: SessionConfigOption) -> Bool {
    option.category == SessionConfigOption.Category.model || option.id == "model"
  }
}
