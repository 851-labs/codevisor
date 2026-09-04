import Autocomplete
import SwiftUI

struct RichItemsStory: View {
  @State private var selection: Command?
  var body: some View {
    Autocomplete.Suggestions {
      for command in SampleData.commands {
        Autocomplete.Action(command.title, id: command.id, systemImage: command.symbol) { selection = command }
          .keyboardShortcut(command.shortcut)
      }
    }
    .autocompleteFilter(.subsequence)
    .autocompleteEmptyMessage("No matching commands")
    .popupSurface()
    .storyInspector { SelectionSection(value: selection?.title) }
  }
}
