import Autocomplete
import CodevisorUI
import SwiftUI

/// The composer's chip and popover presentation. Autocomplete owns the menu
/// behavior; each picker supplies its choices and commands as ordinary options.
struct RunPickerMenu<Target: Hashable>: View {
  let chipText: String
  let chipSymbol: String
  let sections: [Autocomplete.Section<Autocomplete.Option<Target>>]
  let searchAccessibilityLabel: String
  let emptyMessage: String
  var favoriteIDs: Binding<[Target]>? = nil

  @State private var isPresented = false
  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      PickerChip(text: chipText) {
        Image(systemName: chipSymbol)
          .font(.system(size: 12))
      }
    }
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .fixedSize()
    .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
      Autocomplete.Menu(
        sections: sections,
        searchAccessibilityLabel: searchAccessibilityLabel,
        emptyMessage: emptyMessage,
        showsCheckmarks: true,
        favoriteIDs: favoriteIDs,
        onDismiss: { isPresented = false }
      )
    }
  }
}
