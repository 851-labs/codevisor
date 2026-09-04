import ACPKit

enum ModelParameterMenu {
  /// Different parameters can use the same value, so a menu row needs both.
  struct Target: Hashable {
    let optionID: String
    let value: String
  }

  static func options(from options: [SessionConfigOption]) -> [SessionConfigOption] {
    let order = [
      SessionConfigOption.Category.thoughtLevel: 0,
      SessionConfigOption.Category.speed: 1,
      SessionConfigOption.Category.modelConfig: 2,
    ]
    return
      options
      .filter { option in
        !option.options.isEmpty
          && option.category != SessionConfigOption.Category.model
          && option.category != SessionConfigOption.Category.mode
          && option.id != "model"
          && option.id != "mode"
      }
      .sorted { left, right in
        let leftOrder = order[left.category ?? ""] ?? 99
        let rightOrder = order[right.category ?? ""] ?? 99
        if leftOrder == rightOrder { return left.name < right.name }
        return leftOrder < rightOrder
      }
  }

  static func summarized(_ options: [SessionConfigOption]) -> [SessionConfigOption] {
    options.filter { option in
      let isSpeed =
        option.category == SessionConfigOption.Category.speed
        || option.id == "speed"
      return !isSpeed || option.currentValue != "standard"
    }
  }
}
