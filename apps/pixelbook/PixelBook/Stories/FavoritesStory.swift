import Autocomplete
import SwiftUI

/// A one-off UX built from the primitives: a hover-revealed star accessory
/// on each `Item`, and a Favorites `Group` that lifts starred models out of
/// their harness. The package knows nothing about favorites.
struct FavoritesStory: View {
  @State private var favorites: [String] = ["gpt-5-codex", "sonnet"]
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .menu)
  @State private var selection: Model?

  private let harnesses = SampleData.harnesses
  private let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var allModels: [Model] { harnesses.flatMap(\.models) }

  private var visible: [(harness: Harness, models: [Model])] {
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

  private var favoriteModels: [Model] {
    let visibleModels = visible.flatMap(\.models)
    return favorites.compactMap { id in visibleModels.first { $0.id == id } }
  }

  private var regular: [(harness: Harness, models: [Model])] {
    visible.compactMap { harness, models in
      let rest = models.filter { !favorites.contains($0.id) }
      return rest.isEmpty ? nil : (harness, rest)
    }
  }

  var body: some View {
    Autocomplete.Root(highlight: highlight, onDismiss: { query = "" }) {
      Autocomplete.Input(text: $query, prompt: "Filter models")
      Autocomplete.List(height: metrics.listHeight(groupItemCounts: groupItemCounts)) {
        if favoriteModels.isEmpty, regular.isEmpty {
          Autocomplete.Empty("No matching models")
        }
        if !favoriteModels.isEmpty {
          Autocomplete.Group("Favorites") {
            ForEach(favoriteModels) { model in
              row(model, isFavorite: true)
            }
          }
        }
        ForEach(regular, id: \.harness.id) { harness, models in
          Autocomplete.Group(harness.name) {
            ForEach(models) { model in
              row(model, isFavorite: false)
            }
          }
        }
      }
    }
    .frame(width: metrics.popupWidth(fitting: harnesses.flatMap { [$0.name] + $0.models.map(\.name) }))
    .popupSurface()
    .storyInspector {
      Section("Favorites") {
        if favorites.isEmpty {
          Text("None")
            .foregroundStyle(.secondary)
        }
        ForEach(favorites, id: \.self) { id in
          Text(allModels.first { $0.id == id }?.name ?? id)
        }
      }
      SelectionSection(value: selection?.name)
    }
  }

  private func row(_ model: Model, isFavorite: Bool) -> some View {
    let actionName = isFavorite ? "Remove from Favorites" : "Add to Favorites"
    return Autocomplete.Item(
      id: model.id,
      isSelected: model == selection,
      accessibilityAction: Autocomplete.ItemAction(name: actionName) { toggleFavorite(model) },
      action: { choose(model) }
    ) { _ in
      Text(model.name)
    } accessory: { _ in
      Button {
        toggleFavorite(model)
      } label: {
        Image(systemName: isFavorite ? "star.slash" : "star")
          .font(.system(size: 11))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(actionName)
    }
  }

  private var groupItemCounts: [Int] {
    var counts = favorites.isEmpty ? [] : [favorites.count]
    counts += harnesses.map { harness in harness.models.filter { !favorites.contains($0.id) }.count }
    return counts.filter { $0 > 0 }
  }

  private func toggleFavorite(_ model: Model) {
    highlight.reset()
    if let index = favorites.firstIndex(of: model.id) {
      favorites.remove(at: index)
    } else {
      favorites.append(model.id)
    }
  }

  private func choose(_ model: Model) {
    selection = model
  }
}
