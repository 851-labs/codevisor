import Autocomplete
import SwiftUI

struct DisabledStory: View {
  @State private var disabled = false
  @State private var disableFirst = true
  @State private var selection: Language?
  private let languages = SampleData.languages
  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Picker("Languages", selection: $selection, options: languages) { language in
        Autocomplete.Choice(language.name, value: Optional(language))
          .disabled(disableFirst && language == languages.first)
      }.labelsHidden()
    }
    .disabled(disabled)
    .popupSurface()
    .storyInspector {
      Section("Availability") {
        Toggle("Disable entire control", isOn: $disabled)
        Toggle("Disable first choice", isOn: $disableFirst)
      }
      SelectionSection(value: selection?.name)
    }
  }
}
