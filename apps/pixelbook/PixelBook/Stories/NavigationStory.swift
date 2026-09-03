import Autocomplete
import SwiftUI

/// `Navigation` decides what arrows do at the edges and whether the first
/// match is pre-highlighted. `.menu` is Xcode's picker; `.inline` is what an
/// autocomplete under a text field wants so Return accepts immediately.
struct NavigationStory: View {
  @State private var loop = true
  @State private var autoHighlight = true
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .inline)
  @State private var selection: Language?

  private let languages = SampleData.languages
  private let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var matches: [Language] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return languages }
    return languages.filter { Autocomplete.Filter.contains.matches($0.name, query: query) }
  }

  var body: some View {
    Autocomplete.Root(highlight: highlight, onDismiss: { query = "" }) {
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
    .onChange(of: loop, initial: true) { _, loop in highlight.navigation.loop = loop }
    .onChange(of: autoHighlight, initial: true) { _, autoHighlight in
      highlight.navigation.autoHighlight = autoHighlight
      highlight.reconcile(with: matches.map(\.id))
    }
    .storyInspector {
      Section("Navigation") {
        Toggle("Loop at the ends", isOn: $loop)
        Toggle("Auto-highlight first match", isOn: $autoHighlight)
        LabeledContent("Preset", value: presetName)
      }
      SelectionSection(value: selection?.name)
    }
  }

  private var presetName: String {
    switch (loop, autoHighlight) {
    case (true, true): "inline"
    case (false, false): "menu"
    default: "custom"
    }
  }

  private func choose(_ language: Language) {
    selection = language
  }
}
