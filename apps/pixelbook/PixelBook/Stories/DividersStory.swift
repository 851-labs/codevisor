import Autocomplete
import SwiftUI

struct DividersStory: View {
  @State private var selection: String?
  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Section(id: "effort") {
        for title in ["Low", "Medium", "High", "X-High", "Max"] {
          Autocomplete.Action(title) { selection = title }
        }
      }
      Autocomplete.Section(id: "speed") {
        for title in ["Standard", "Fast"] { Autocomplete.Action(title) { selection = title } }
      }
    }
    .popupSurface()
    .storyInspector { SelectionSection(value: selection) }
  }
}
