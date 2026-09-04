import Autocomplete
import SwiftUI

/// `Empty` fills the list's visible height so the message sits centered,
/// whether there is nothing to show or the filter matched nothing.
struct EmptyStory: View {
  @State private var hasItems = false
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .menu)

  private let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var items: [Language] {
    hasItems ? SampleData.languages : []
  }

  private var matches: [Language] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return items }
    return items.filter { Autocomplete.Filter.contains.matches($0.name, query: query) }
  }

  var body: some View {
    Autocomplete.Root(highlight: highlight, onDismiss: { query = "" }) {
      Autocomplete.Input(text: $query, prompt: "Search")
      Autocomplete.List(height: metrics.listHeight(itemCount: items.count)) {
        if matches.isEmpty {
          Autocomplete.Empty(items.isEmpty ? "No languages available" : "No matching languages")
        }
        ForEach(matches) { language in
          Autocomplete.Item(id: language.id, action: {}) { _ in
            Text(language.name)
          }
        }
      }
    }
    .frame(width: metrics.minimumWidth)
    .popupSurface()
    .storyInspector {
      Section("Contents") {
        Toggle("Provide items", isOn: $hasItems)
      }
    }
  }
}
