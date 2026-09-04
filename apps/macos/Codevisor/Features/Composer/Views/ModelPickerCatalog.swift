import Foundation
import ACPKit
import Autocomplete

/// A keyboard/hover target in the model picker: a model row or the footer.
enum ModelPickerTarget: Hashable {
  case model(groupID: String, value: String)
  case manageHarnesses
}

struct ModelMenuGroup: Identifiable {
  let id: String
  let name: String
  let symbolName: String
  let modelOption: SessionConfigOption

  func matchingModels(query: String) -> [SessionConfigSelectOption] {
    guard !query.isEmpty else { return modelOption.options }
    if name.localizedCaseInsensitiveContains(query) { return modelOption.options }
    return modelOption.options.filter {
      $0.name.localizedCaseInsensitiveContains(query)
        || $0.value.localizedCaseInsensitiveContains(query)
    }
  }
}

struct ModelPickerFavorite: Codable, Hashable {
  let harnessID: String
  let modelValue: String

  init(model: SessionConfigSelectOption, group: ModelMenuGroup) {
    harnessID = group.id
    modelValue = model.value
  }
}

/// One titled run of picker rows.
struct ModelPickerSection: Identifiable {
  let id: String
  let title: String
  let items: [ModelPickerModelItem]
}

struct ModelPickerModelItem: Identifiable {
  let group: ModelMenuGroup
  let model: SessionConfigSelectOption
  let isFavorite: Bool

  var id: ModelPickerTarget {
    .model(groupID: group.id, value: model.value)
  }

  var favorite: ModelPickerFavorite {
    ModelPickerFavorite(model: model, group: group)
  }

  var favoriteAction: Autocomplete.FavoriteAction {
    Autocomplete.FavoriteAction(isFavorite: isFavorite)
  }
}

/// The picker's rows for one query: a Favorites section first, then each
/// harness with its favorited models removed so a model is listed once.
struct ModelPickerCatalog {
  let groups: [ModelMenuGroup]
  let favoriteIDs: [ModelPickerFavorite]
  let query: String

  private var favoriteSet: Set<ModelPickerFavorite> {
    Set(favoriteIDs)
  }

  var favorites: [ModelPickerModelItem] {
    favoriteIDs.compactMap { favorite in
      guard
        let group = groups.first(where: { $0.id == favorite.harnessID }),
        let model = group.matchingModels(query: query).first(where: {
          $0.value == favorite.modelValue
        })
      else { return nil }
      return ModelPickerModelItem(group: group, model: model, isFavorite: true)
    }
  }

  var sections: [ModelPickerSection] {
    var sections: [ModelPickerSection] = []
    let favorites = favorites
    if !favorites.isEmpty {
      sections.append(ModelPickerSection(id: "favorites", title: "Favorites", items: favorites))
    }
    for group in groups {
      let items = regularModels(in: group).map {
        ModelPickerModelItem(group: group, model: $0, isFavorite: false)
      }
      guard !items.isEmpty else { continue }
      sections.append(ModelPickerSection(id: group.id, title: group.name, items: items))
    }
    return sections
  }

  /// Rows per section, for sizing the list.
  var groupItemCounts: [Int] {
    sections.map(\.items.count)
  }

  /// Every title the unfiltered picker can show, for sizing the panel.
  var allTitles: [String] {
    groups.flatMap { group in [group.name] + group.modelOption.options.map(\.name) }
  }

  private func regularModels(in group: ModelMenuGroup) -> [SessionConfigSelectOption] {
    group.matchingModels(query: query).filter {
      !favoriteSet.contains(ModelPickerFavorite(model: $0, group: group))
    }
  }
}
