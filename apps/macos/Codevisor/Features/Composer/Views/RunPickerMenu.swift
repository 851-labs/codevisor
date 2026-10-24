import Autocomplete
import CodevisorUI
import SwiftUI

struct RunPickerMenu: View {
  let chipText: String
  let chipSymbol: String
  let entries: [Autocomplete.Entry]
  var isPresented: Binding<Bool>?

  init(
    chipText: String, chipSymbol: String, isPresented: Binding<Bool>? = nil,
    @Autocomplete.ContentBuilder content: () -> [Autocomplete.Entry]
  ) {
    self.chipText = chipText
    self.chipSymbol = chipSymbol
    self.isPresented = isPresented
    entries = content()
  }

  var body: some View {
    Autocomplete.Menu(isPresented: isPresented) {
      entries
    } label: {
      PickerChip(text: chipText) {
        Image(systemName: chipSymbol).font(.system(size: 12))
      }
    }
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .hoverChipOverflow()
    .fixedSize()
  }
}
