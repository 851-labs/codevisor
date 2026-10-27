import SwiftUI

struct PaletteDestinations: Equatable {
  let bots: @MainActor () -> [CommandPaletteItem]
  let workspaces: @MainActor () -> [CommandPaletteItem]

  static func == (lhs: PaletteDestinations, rhs: PaletteDestinations) -> Bool { true }
}

private struct PaletteDestinationsKey: FocusedValueKey {
  typealias Value = PaletteDestinations
}

extension FocusedValues {
  var paletteDestinations: PaletteDestinations? {
    get { self[PaletteDestinationsKey.self] }
    set { self[PaletteDestinationsKey.self] = newValue }
  }
}
