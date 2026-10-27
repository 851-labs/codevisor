import Autocomplete
import CodevisorUI
import SwiftUI

struct RunPickerMenu: View {
  let chipText: String
  let chipIcon: Image
  let entries: [Autocomplete.Entry]
  var isPresented: Binding<Bool>?

  init(
    chipText: String, chipIcon: Image, isPresented: Binding<Bool>? = nil,
    @Autocomplete.ContentBuilder content: () -> [Autocomplete.Entry]
  ) {
    self.chipText = chipText
    self.chipIcon = chipIcon
    self.isPresented = isPresented
    entries = content()
  }

  var body: some View {
    Autocomplete.Menu(isPresented: isPresented) {
      entries
    } label: {
      PickerChip(text: chipText) {
        chipIcon.font(.system(size: 12))
      }
    }
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .hoverChipOverflow()
    .fixedSize()
  }
}
