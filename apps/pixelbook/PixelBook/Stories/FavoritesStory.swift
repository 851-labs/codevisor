import Autocomplete
import SwiftUI

struct FavoritesStory: View {
  @State private var favorites = ["gpt-5-codex", "sonnet"]
  @State private var selection = ""
  @State private var reversed = false
  private var harnesses: [Harness] { reversed ? SampleData.harnesses.reversed() : SampleData.harnesses }
  private var models: [Model] { harnesses.flatMap(\.models) }
  var body: some View {
    Autocomplete.Suggestions {
      ForEach(harnesses) { harness in
        Autocomplete.Picker(harness.name, id: harness.id, selection: $selection, options: harness.models) { model in
          Autocomplete.Choice(model.name, value: model.id)
        }.favorites($favorites)
      }
    }
    .autocompleteSearchLabel("Search models")
    .popupSurface()
    .storyInspector {
      Section("Favorites") {
        Text("Highlight a row and press ⇧⌘F, or Tab to its star.")
        ForEach(favorites, id: \.self) { id in Text(models.first { $0.id == id }?.name ?? id) }
        Toggle("Reverse group order", isOn: $reversed)
      }
      SelectionSection(value: models.first { $0.id == selection }?.name)
    }
  }
}
