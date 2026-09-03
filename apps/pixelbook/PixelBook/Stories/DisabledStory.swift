import Autocomplete
import SwiftUI

/// `Root(isDisabled:)` dims every item, ignores the pointer, arrows, clicks,
/// and Return, and hides accessories — for the moment between choosing and
/// the choice taking effect. Escape still dismisses.
struct DisabledStory: View {
  @State private var isDisabled = true
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .menu)
  @State private var selection: Language?

  private let languages = SampleData.languages
  private let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var matches: [Language] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return languages }
    return languages.filter { Autocomplete.Filter.contains.matches($0.name, query: query) }
  }

  var body: some View {
    Autocomplete.Root(highlight: highlight, isDisabled: isDisabled, onDismiss: { query = "" }) {
      Autocomplete.Input(text: $query, prompt: "Filter languages")
      Autocomplete.List(height: metrics.listHeight(itemCount: languages.count)) {
        if matches.isEmpty {
          Autocomplete.Empty("No matching languages")
        }
        ForEach(matches) { language in
          Autocomplete.Item(id: language.id, isSelected: language == selection, action: { choose(language) }) { _ in
            Text(language.name)
          }
        }
      }
    }
    .frame(width: metrics.popupWidth(fitting: languages.map(\.name)))
    .popupSurface()
    .storyInspector {
      Section("State") {
        Toggle("Disabled", isOn: $isDisabled)
      }
      SelectionSection(value: selection?.name)
    }
  }

  private func choose(_ language: Language) {
    selection = language
  }
}
