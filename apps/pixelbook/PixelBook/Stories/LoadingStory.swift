import Autocomplete
import SwiftUI

struct LoadingStory: View {
  @State private var state = 0
  @State private var selection: Language?
  private var loading: Autocomplete.LoadingState {
    switch state {
    case 1: .loading("Loading languages…")
    case 2: .failure("Could not load languages")
    default: .ready
    }
  }
  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Picker("Language", selection: $selection, options: SampleData.languages) { language in
        Autocomplete.Choice(language.name, value: Optional(language))
      }.labelsHidden()
    }
    .autocompleteLoadingState(loading)
    .popupSurface()
    .storyInspector {
      Section("Loading") {
        Picker("State", selection: $state) {
          Text("Ready").tag(0)
          Text("Loading").tag(1)
          Text("Error").tag(2)
        }
        if state == 2 { Button("Retry") { state = 0 } }
      }
      SelectionSection(value: selection?.name)
    }
  }
}
