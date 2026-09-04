import Autocomplete
import CodevisorUI
import SwiftUI

/// Shared composer trigger styling. Autocomplete owns presentation and behavior.
struct RunPickerMenu: View {
  let chipText: String
  let chipSymbol: String
  let entries: [Autocomplete.Entry]

  init(chipText: String, chipSymbol: String, @Autocomplete.ContentBuilder content: () -> [Autocomplete.Entry]) {
    self.chipText = chipText
    self.chipSymbol = chipSymbol
    entries = content()
  }

  var body: some View {
    Autocomplete.Menu {
      entries
    } label: {
      PickerChip(text: chipText) {
        Image(systemName: chipSymbol).font(.system(size: 12))
      }
    }
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .fixedSize()
  }
}
