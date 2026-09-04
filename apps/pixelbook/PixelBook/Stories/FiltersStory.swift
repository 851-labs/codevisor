import Autocomplete
import SwiftUI

/// Change matching behavior without reimplementing filtering.
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
      case .contains: "Case- and diacritic-insensitive substring."
      case .startsWith: "Anchored at the start of the candidate."
      case .subsequence: "Query characters in order, gaps allowed."
      }
    }
  }

  @State private var preset: Preset = .contains
  @State private var selection: Language?

  private let languages = SampleData.languages

  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Picker("Languages", selection: $selection, options: languages) { language in
        Autocomplete.Choice(language.name, value: Optional(language))
      }.labelsHidden()
    }
    .autocompleteFilter(preset.filter)
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
