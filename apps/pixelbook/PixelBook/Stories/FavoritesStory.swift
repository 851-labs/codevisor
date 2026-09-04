import Autocomplete
import SwiftUI

/// The menu owns star accessories, favorite ordering, filtering, and section
/// layout. The caller supplies eligible options and storage for favorite IDs.
struct FavoritesStory: View {
  @State private var favorites: [String] = ["gpt-5-codex", "sonnet"]
  @State private var selection: Model?

  private let harnesses = SampleData.harnesses
  private var allModels: [Model] { harnesses.flatMap(\.models) }

  var body: some View {
    Autocomplete.Menu(
      sections: harnesses.map { harness in
        .init(
          id: harness.id, title: harness.name,
          items: harness.models.map { model in
            Autocomplete.Option(
              id: model.id, title: model.name, keywords: [harness.name],
              isSelected: model == selection, isFavoritable: true
            ) {
              selection = model
            }
          }
        )
      },
      searchAccessibilityLabel: "Search models",
      emptyMessage: "No matching models",
      showsCheckmarks: true,
      favoriteIDs: $favorites,
      onDismiss: {}
    )
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
}
