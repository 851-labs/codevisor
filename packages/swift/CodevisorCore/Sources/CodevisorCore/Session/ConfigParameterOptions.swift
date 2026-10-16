import ACPKit

public enum ConfigParameterOptions {
  public static func ordered(_ options: [SessionConfigOption]) -> [SessionConfigOption] {
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
}
