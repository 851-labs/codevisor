import Autocomplete
import SwiftUI

/// A single-choice menu with a checkmark on the current effort level.
struct CheckmarksStory: View {
  @State private var effort = "High"

  private let efforts = ["Low", "Medium", "High", "X-High", "Max"]

  var body: some View {
    Autocomplete.Menu(
      sections: [
        .init(
          id: "effort",
          items: efforts.map { title in
            Autocomplete.Option(id: title, title: title, isSelected: effort == title) {
              effort = title
            }
          })
      ],
      searchAccessibilityLabel: "Search effort levels",
      emptyMessage: "No matching effort levels",
      showsCheckmarks: true,
      onDismiss: {}
    )
    .popupSurface()
    .storyInspector {
      Section("Selection") {
        LabeledContent("Effort", value: effort)
      }
    }
  }
}
