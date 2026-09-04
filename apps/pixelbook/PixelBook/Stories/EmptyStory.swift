import Autocomplete
import SwiftUI

struct EmptyStory: View {
  @State private var hasItems = false
  var body: some View {
    Autocomplete.Suggestions {
      if hasItems {
        for language in SampleData.languages { Autocomplete.Action(language.name) {} }
      }
    }
    .autocompleteEmptyMessage("No matching languages", noItems: "No languages available")
    .popupSurface()
    .storyInspector { Section("Contents") { Toggle("Provide items", isOn: $hasItems) } }
  }
}
