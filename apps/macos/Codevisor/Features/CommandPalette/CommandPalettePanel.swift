import Autocomplete
import CodevisorUI
import SwiftUI

struct CommandPalettePanel: View {
  @Bindable var palette: CommandPalette
  let store: SessionStore?
  @State private var inputFocus = Autocomplete.InputFocus()

  private static let cornerRadius: CGFloat = 18
  private static let width: CGFloat = 440
  private static let maximumHeight: CGFloat = 460

  var body: some View {
    Autocomplete.Suggestions(query: $palette.query, focus: inputFocus, onCancel: palette.dismiss) {
      for section in palette.sections {
        Autocomplete.Section(section.title, id: section.id) {
          for item in section.items {
            action(for: item)
          }
        }
      }
    }
    .autocompleteSearchPrompt("Search commands and workspaces…")
    .autocompleteSearchLabel("Command palette")
    .autocompleteEmptyMessage("No matching commands or workspaces")
    .autocompleteSizing(.fitResults)
    .autocompleteNavigation(Autocomplete.Navigation(loop: false, autoHighlight: true))
    .autocompleteStyle(Autocomplete.Style(metrics: Self.metrics))
    .composerGlassSurface(cornerRadius: Self.cornerRadius)
    .background(CommandPaletteClickMonitor(onClickOutside: palette.dismiss))
    .onAppear { inputFocus.focus() }
  }

  private static var metrics: Autocomplete.Metrics {
    var metrics = Autocomplete.Metrics.xcodeMenu
    metrics.minimumWidth = width
    metrics.maximumWidth = width
    metrics.maximumHeight = maximumHeight
    return metrics
  }

  private func action(for item: CommandPaletteItem) -> Autocomplete.Action {
    let run = { palette.run(item) }
    let action =
      if let icon = item.icon {
        Autocomplete.Action(item.title, id: item.id, action: run) {
          CommandPaletteItemIcon(icon: icon, store: store)
        } label: {
          CommandPaletteItemLabel(title: item.title, subtitle: item.subtitle)
        }
      } else {
        Autocomplete.Action(item.title, id: item.id, action: run)
      }
    return action.keyboardShortcut(item.shortcut).searchTerms(item.searchTerms)
  }
}
