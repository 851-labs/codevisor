import Autocomplete
import SwiftUI

struct GroupsStory: View {
  @State private var selection = ""
  private let harnesses = SampleData.harnesses
  var body: some View {
    Autocomplete.Suggestions {
      ForEach(harnesses) { harness in
        Autocomplete.Picker(harness.name, id: harness.id, selection: $selection, options: harness.models) { model in
          Autocomplete.Choice(model.name, value: model.id)
        }
      }
    }
    .autocompleteSearchLabel("Search models")
    .popupSurface()
    .storyInspector { SelectionSection(value: harnesses.flatMap(\.models).first { $0.id == selection }?.name) }
  }
}
