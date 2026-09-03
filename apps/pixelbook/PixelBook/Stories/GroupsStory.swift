import Autocomplete
import SwiftUI

/// `Group` gives runs of items a secondary-styled label. Typing a group's
/// name keeps its whole run visible.
struct GroupsStory: View {
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .menu)
  @State private var selection: Model?

  private let harnesses = SampleData.harnesses
  private let metrics = Autocomplete.Style.xcodeMenu.metrics

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
    Autocomplete.Root(highlight: highlight, onDismiss: { query = "" }) {
      Autocomplete.Input(text: $query, prompt: "Search")
      Autocomplete.List(height: metrics.listHeight(groupItemCounts: harnesses.map(\.models.count))) {
        if matches.isEmpty {
          Autocomplete.Empty("No matching models")
        }
        ForEach(matches, id: \.harness.id) { harness, models in
          Autocomplete.Group(harness.name) {
            ForEach(models) { model in
              Autocomplete.Item(id: model.id, isSelected: model == selection, action: { choose(model) }) { _ in
                Text(model.name)
              }
            }
          }
        }
      }
    }
    .frame(width: metrics.popupWidth(fitting: harnesses.flatMap { [$0.name] + $0.models.map(\.name) }))
    .popupSurface()
    .storyInspector {
      SelectionSection(value: selection?.name)
    }
  }

  private func choose(_ model: Model) {
    selection = model
  }
}
