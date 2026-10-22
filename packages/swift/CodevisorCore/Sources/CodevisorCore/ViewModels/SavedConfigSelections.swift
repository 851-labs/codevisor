import Foundation
import ACPKit

struct SavedConfigSelections {
  let saved: [SessionConfigOption]

  func restored(onto options: [SessionConfigOption]) -> [SessionConfigOption] {
    options.map(restoring)
  }

  private func restoring(_ option: SessionConfigOption) -> SessionConfigOption {
    guard let value = savedValue(for: option) else { return option }
    var restored = option
    restored.currentValue = value
    return restored
  }

  private func savedValue(for option: SessionConfigOption) -> String? {
    guard let selection = saved.first(where: { $0.id == option.id }),
      option.options.contains(where: { $0.value == selection.currentValue })
    else { return nil }
    return selection.currentValue
  }
}
