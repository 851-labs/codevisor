import Autocomplete
import SwiftUI

struct FocusStory: View {
  @State private var query = ""
  @State private var elsewhere = ""
  @State private var isSearchFocused = false
  @State private var accepted = 0
  @State private var submitted = 0
  var body: some View {
    Autocomplete.Suggestions(query: $query, onSubmit: { submitted += 1 }) {
      Autocomplete.Action("Open project", systemImage: "folder") { accepted += 1 }
        .keyboardShortcut("o")
    }
    .autocompleteSearchFocused($isSearchFocused)
    .popupSurface()
    .storyInspector {
      Section("Focus") {
        TextField("Another field", text: $elsewhere)
        Button("Focus search") { isSearchFocused = true }
        LabeledContent("Search focused", value: isSearchFocused ? "Yes" : "No")
        LabeledContent("Selected", value: "\(accepted)")
        LabeledContent("Unhandled submits", value: "\(submitted)")
        Text(
          "Try text composition, Control-N/P, Control-K, and Command-O. Shortcuts apply only inside the autocomplete.")
      }
    }
  }
}
