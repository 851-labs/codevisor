import Autocomplete
import SwiftUI

/// The package ships three `Filter` presets; the popup does not filter for
/// you, so swapping one is a one-line change in the caller.
struct FiltersStory: View {
  enum Preset: String, CaseIterable, Identifiable {
    case contains = "Contains"
    case startsWith = "Starts with"
    case subsequence = "Subsequence"

    var id: String { rawValue }

    var filter: Autocomplete.Filter {
      switch self {
      case .contains: .contains
      case .startsWith: .startsWith
      case .subsequence: .subsequence
      }
    }

    var hint: String {
      switch self {
      case .contains: "Case- and diacritic-insensitive substring. Try “ip”."
      case .startsWith: "Anchored at the start. “ip” matches nothing; “ty” matches TypeScript."
      case .subsequence: "Characters in order, gaps allowed. “tsp” matches TypeScript."
      }
    }
  }

  @State private var preset: Preset = .contains
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .menu)
  @State private var selection: Language?

  private let languages = SampleData.languages
  private let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var matches: [Language] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return languages }
    return languages.filter { preset.filter.matches($0.name, query: query) }
  }

  var body: some View {
    Autocomplete.Root(highlight: highlight, onDismiss: { query = "" }) {
      Autocomplete.Input(text: $query, prompt: "Filter languages")
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
    .popupSurface()
    .storyInspector {
      Section("Filter") {
        Picker("Preset", selection: $preset) {
          ForEach(Preset.allCases) { preset in
            Text(preset.rawValue).tag(preset)
          }
        }
        Text(preset.hint)
          .foregroundStyle(.secondary)
      }
      SelectionSection(value: selection?.name)
    }
  }
}
