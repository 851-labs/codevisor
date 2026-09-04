import Autocomplete
import SwiftUI

/// Choices and commands participate in the same search and navigation.
struct ActionsStory: View {
  @State private var selection = ""
  @State private var managePresses = 0
  var body: some View {
    Autocomplete.Suggestions {
      for harness in SampleData.harnesses {
        Autocomplete.Picker(harness.name, id: harness.id, selection: $selection, options: harness.models) { model in
          Autocomplete.Choice(model.name, value: model.id)
        }
      }
      Autocomplete.Section(id: "actions") {
        Autocomplete.Action("Manage Harnesses…", systemImage: "gearshape") { managePresses += 1 }
          .keyboardShortcut(",")
          .help("Open Harness Settings")
      }
    }
    .popupSurface()
    .storyInspector {
      SelectionSection(value: selection)
      Section("Action") { LabeledContent("Manage", value: "Pressed \(managePresses) times") }
    }
  }
}
