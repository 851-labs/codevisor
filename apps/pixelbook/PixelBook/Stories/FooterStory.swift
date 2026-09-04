import Autocomplete
import SwiftUI

/// `Footer` pins ordinary `Item`s under the list behind a divider — the
/// "manage the things in this list" escape hatch. They are regular rows:
/// icons, shortcuts, and keyboard navigation all work, and the popup's last
/// row takes the concentric bottom corners.
struct FooterStory: View {
  enum Target: Hashable {
    case model(String)
    case manage
  }

  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<Target>(navigation: .menu)
  @State private var selection: Model?
  @State private var managePresses = 0

  private let harnesses = SampleData.harnesses
  private let metrics = Autocomplete.Style.xcodeMenu.metrics
  private let footerTitle = "Manage Harnesses…"

  private var matches: [(harness: Harness, models: [Model])] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filter = Autocomplete.Filter.contains
    return harnesses.compactMap { harness in
      if query.isEmpty || filter.matches(harness.name, query: query) {
        return (harness, harness.models)
      }
      let models = harness.models.filter { filter.matches($0.name, query: query) }
      return models.isEmpty ? nil : (harness, models)
    }
  }

  var body: some View {
    Autocomplete.Root(highlight: highlight, showsIcons: true, onDismiss: { query = "" }) {
      Autocomplete.Input(text: $query, prompt: "Search")
      Autocomplete.List(height: metrics.listHeight(groupItemCounts: harnesses.map(\.models.count), footerItemCount: 1))
      {
        if matches.isEmpty {
          Autocomplete.Empty("No matching models")
        }
        ForEach(matches, id: \.harness.id) { harness, models in
          Autocomplete.Group(harness.name) {
            ForEach(models) { model in
              Autocomplete.Item(id: Target.model(model.id), isSelected: model == selection, action: { choose(model) }) {
                _ in
                Text(model.name)
              }
            }
          }
        }
      }
      Autocomplete.Footer {
        Autocomplete.Item(
          id: Target.manage,
          icon: Image(systemName: "gearshape"),
          shortcut: KeyboardShortcut(","),
          action: manage
        ) { _ in
          Text(footerTitle)
        }
        .help("Open Harness Settings")
      }
    }
    .frame(
      width: metrics.popupWidth(
        fitting: harnesses.flatMap { [$0.name] + $0.models.map(\.name) } + [footerTitle],
        hasIcons: true,
        shortcuts: [KeyboardShortcut(",")]
      )
    )
    .popupSurface()
    .storyInspector {
      SelectionSection(value: selection?.name)
      Section("Footer") {
        LabeledContent("Manage Harnesses…", value: managePresses == 0 ? "Not pressed" : "Pressed \(managePresses)×")
      }
    }
  }

  private func choose(_ model: Model) {
    selection = model
  }

  private func manage() {
    managePresses += 1
  }
}
