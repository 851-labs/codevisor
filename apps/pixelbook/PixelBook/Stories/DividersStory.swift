import Autocomplete
import SwiftUI

/// Two runs of ordinary items separated by a divider. Search can leave
/// either run, both, or neither; the menu keeps separators between results.
struct DividersStory: View {
  @State private var selection: String?

  var body: some View {
    Autocomplete.Menu(
      sections: [
        .init(id: "effort", items: options(["Low", "Medium", "High", "X-High", "Max"])),
        .init(id: "speed", items: options(["Standard", "Fast"])),
      ],
      searchAccessibilityLabel: "Search options",
      emptyMessage: "No matching options",
      onDismiss: {}
    )
    .popupSurface()
    .storyInspector {
      SelectionSection(value: selection)
    }
  }

  private func options(_ titles: [String]) -> [Autocomplete.Option<String>] {
    titles.map { title in
      Autocomplete.Option(id: title, title: title) {
        selection = title
      }
    }
  }
}
