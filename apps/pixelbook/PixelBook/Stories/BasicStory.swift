import Autocomplete
import SwiftUI

/// A selection binding is all the caller needs; the package owns interaction.
struct BasicStory: View {
  @State private var selection: Language?
  private let languages = SampleData.languages
  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Picker("Languages", selection: $selection, options: languages) { language in
        Autocomplete.Choice(language.name, value: Optional(language))
      }.labelsHidden()
    }
    .autocompleteNavigation(.menu)
    .autocompleteSearchLabel("Search languages")
    .autocompleteEmptyMessage("No matching languages")
    .popupSurface()
    .storyInspector { SelectionSection(value: selection?.name) }
  }
}
