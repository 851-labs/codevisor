import ACPKit
import CodevisorCore

enum ModelParameterMenu {
  static func options(from options: [SessionConfigOption]) -> [SessionConfigOption] {
    ConfigParameterOptions.ordered(options)
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
