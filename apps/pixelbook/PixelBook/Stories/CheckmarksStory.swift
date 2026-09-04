import Autocomplete
import SwiftUI

struct CheckmarksStory: View {
  @State private var effort = "High"
  private let efforts = ["Low", "Medium", "High", "X-High", "Max"]
  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Picker("Effort", selection: $effort) {
        ForEach(efforts, id: \.self) { title in Autocomplete.Choice(title, value: title) }
      }.labelsHidden()
    }
    .popupSurface()
    .storyInspector { Section("Selection") { LabeledContent("Effort", value: effort) } }
  }
}
