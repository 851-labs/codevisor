import Autocomplete
import SwiftUI

/// `Style` swaps the highlight (system menu material vs. a flat fill) and the
/// scroller. A flat fill is what an inline popup on a glass surface wants.
struct CustomStyleStory: View {
  enum Highlight: String, CaseIterable, Identifiable {
    case menuSelection = "Menu selection"
    case accent = "Accent fill"
    case tinted = "Tinted fill"

    var id: String { rawValue }

    var itemHighlight: Autocomplete.ItemHighlight {
      switch self {
      case .menuSelection: .menuSelection
      case .accent: .fill(.accentColor)
      case .tinted: .fill(.indigo)
      }
    }
  }

  @State private var highlightChoice: Highlight = .tinted
  @State private var usesMiniScroller = false
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .inline)
  @State private var selection: Language?

  private let languages = SampleData.manyLanguages
  private let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var style: Autocomplete.Style {
    Autocomplete.Style(itemHighlight: highlightChoice.itemHighlight, usesMiniScroller: usesMiniScroller)
  }

  private var matches: [Language] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return languages }
    return languages.filter { Autocomplete.Filter.contains.matches($0.name, query: query) }
  }

  var body: some View {
    Autocomplete.Root(highlight: highlight, onDismiss: { query = "" }) {
      Autocomplete.Input(text: $query, prompt: "Search")
      Autocomplete.List(height: metrics.listHeight(itemCount: languages.count)) {
        if matches.isEmpty {
          Autocomplete.Empty("No matching languages")
        }
        ForEach(matches) { language in
          Autocomplete.Item(id: language.id, isSelected: language == selection, action: { selection = language }) { _ in
            Text(language.name)
          }
        }
      }
    }
    .frame(width: metrics.popupWidth(fitting: languages.map(\.name)))
    .autocompleteStyle(style)
    .popupSurface()
    .storyInspector {
      Section("Style") {
        Picker("Highlight", selection: $highlightChoice) {
          ForEach(Highlight.allCases) { choice in
            Text(choice.rawValue).tag(choice)
          }
        }
        Toggle("Mini scroller", isOn: $usesMiniScroller)
      }
      SelectionSection(value: selection?.name)
    }
  }
}
