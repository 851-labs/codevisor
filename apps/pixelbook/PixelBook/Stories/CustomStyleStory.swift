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
      case .tinted: .fill(.yellow, foreground: .black)
      }
    }
  }

  @State private var highlightChoice: Highlight = .tinted
  @State private var usesMiniScroller = false
  @State private var selection: Language?

  private let languages = SampleData.manyLanguages

  private var style: Autocomplete.Style {
    Autocomplete.Style(itemHighlight: highlightChoice.itemHighlight, usesMiniScroller: usesMiniScroller)
  }

  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Picker("Languages", selection: $selection, options: languages) { language in
        Autocomplete.Choice(language.name, value: Optional(language))
      }.labelsHidden()
    }
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
