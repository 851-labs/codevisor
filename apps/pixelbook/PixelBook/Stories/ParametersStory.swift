import Autocomplete
import SwiftUI

struct ParametersStory: View {
  @State private var effort = "High"
  @State private var speed = "Standard"
  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Picker("Effort", selection: $effort) {
        for title in ["Low", "Medium", "High", "X-High", "Max"] { Autocomplete.Choice(title, value: title) }
      }
      Autocomplete.Picker("Speed", selection: $speed) {
        for title in ["Standard", "Fast"] { Autocomplete.Choice(title, value: title) }
      }
    }
    .autocompleteSectionDividers(.hidden)
    .popupSurface()
    .storyInspector {
      Section("Selections") {
        LabeledContent("Effort", value: effort)
        LabeledContent("Speed", value: speed)
      }
    }
  }
}
