import Autocomplete
import SwiftUI

/// `Item`'s first-party icon and shortcut slots: a leading glyph in a fixed
/// column and a dimmed key equivalent at the trailing edge, both inverting
/// on highlight. Command-palette rows without any custom label layout.
struct RichItemsStory: View {
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .inline)
  @State private var selection: Command?

  private let commands = SampleData.commands
  private let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var matches: [Command] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return commands }
    return commands.filter { Autocomplete.Filter.subsequence.matches($0.title, query: query) }
  }

  var body: some View {
    Autocomplete.Root(highlight: highlight, onDismiss: { query = "" }) {
      Autocomplete.Input(text: $query, prompt: "Search")
      Autocomplete.List(height: metrics.listHeight(itemCount: commands.count)) {
        if matches.isEmpty {
          Autocomplete.Empty("No matching commands")
        }
        ForEach(matches) { command in
          Autocomplete.Item(
            id: command.id,
            icon: Image(systemName: command.symbol),
            shortcut: command.shortcut,
            action: { run(command) }
          ) { _ in
            Text(command.title)
          }
        }
      }
    }
    .frame(width: 320)
    .popupSurface()
    .storyInspector {
      SelectionSection(value: selection?.title)
    }
  }

  private func run(_ command: Command) {
    selection = command
  }
}
