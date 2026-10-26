import AppKit
import SwiftUI

@Observable
final class CommandPalette {
  private(set) var sections: [CommandPaletteSection] = []
  private(set) var isPresented = false
  var query = ""
  @ObservationIgnored private var focusReturn: CommandPaletteFocusReturn?

  func toggle(_ sections: [CommandPaletteSection], in window: NSWindow?) {
    if isPresented {
      dismiss()
    } else {
      present(sections, in: window)
    }
  }

  func dismiss() {
    guard isPresented else { return }

    isPresented = false
    focusReturn?.restore()
    focusReturn = nil
  }

  func run(_ item: CommandPaletteItem) {
    dismiss()
    item.perform()
  }

  private func present(_ sections: [CommandPaletteSection], in window: NSWindow?) {
    self.sections = sections
    query = ""
    focusReturn = window.map(CommandPaletteFocusReturn.init)
    isPresented = true
  }
}

private struct CommandPaletteKey: FocusedValueKey {
  typealias Value = CommandPalette
}

extension FocusedValues {
  var commandPalette: CommandPalette? {
    get { self[CommandPaletteKey.self] }
    set { self[CommandPaletteKey.self] = newValue }
  }
}
