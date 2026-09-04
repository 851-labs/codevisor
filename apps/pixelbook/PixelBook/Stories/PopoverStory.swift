import Autocomplete
import SwiftUI

struct PopoverStory: View {
  @State private var isPresented = false
  @State private var selection: Language?
  private let languages = SampleData.languages
  var body: some View {
    Autocomplete.Menu(isPresented: $isPresented) {
      Autocomplete.Picker("Languages", selection: $selection, options: languages) { language in
        Autocomplete.Choice(language.name, value: Optional(language))
      }.labelsHidden()
    } label: {
      Text(selection?.name ?? "Choose a language")
    }
    .buttonStyle(.glass)
    .autocompleteSearchLabel("Search languages")
    .storyInspector {
      Section("Presentation") { LabeledContent("Popover", value: isPresented ? "Shown" : "Hidden") }
      SelectionSection(value: selection?.name)
    }
  }
}
