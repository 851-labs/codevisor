import Autocomplete
import SwiftUI

/// `Item` takes any label. A command palette row: symbol, title, dimmed
/// detail, and a trailing shortcut, all inverting on highlight.
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
      Autocomplete.Input(text: $query, prompt: "Run a command")
      Autocomplete.List(height: metrics.listHeight(itemCount: commands.count)) {
        if matches.isEmpty {
          Autocomplete.Empty("No matching commands")
        }
        ForEach(matches) { command in
          Autocomplete.Item(id: command.id, action: { run(command) }) { context in
            HStack(spacing: 8) {
              Image(systemName: command.symbol)
                .frame(width: 16)
              Text(command.title)
              Text(command.detail)
                .lineLimit(1)
                .foregroundStyle(
                  context.isHighlighted ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
              Spacer(minLength: 12)
              if let shortcut = command.shortcut {
                Text(shortcut)
                  .foregroundStyle(
                    context.isHighlighted ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
              }
            }
          }
        }
      }
    }
    .frame(width: 420)
    .popupSurface()
    .storyInspector {
      SelectionSection(value: selection?.title)
    }
  }

  private func run(_ command: Command) {
    selection = command
  }
}
