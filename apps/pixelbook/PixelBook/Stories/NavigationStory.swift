import Autocomplete
import SwiftUI

/// `Navigation` decides what arrows do at the edges and whether the first
/// match is pre-highlighted. `.menu` is Xcode's picker; `.inline` is what an
/// autocomplete under a text field wants so Return accepts immediately.
struct NavigationStory: View {
  @State private var loop = true
  @State private var autoHighlight = true
  @State private var selection: Language?

  private let languages = SampleData.languages

  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Picker("Languages", selection: $selection, options: languages) { language in
        Autocomplete.Choice(language.name, value: Optional(language))
      }.labelsHidden()
    }
    .autocompleteNavigation(.init(loop: loop, autoHighlight: autoHighlight))
    .popupSurface()
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

}
