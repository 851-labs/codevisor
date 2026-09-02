import ACPKit

struct ModelPickerFavorite: Codable, Hashable {
  let harnessID: String
  let modelValue: String

  init(model: SessionConfigSelectOption, group: ModelMenuGroup) {
    harnessID = group.id
    modelValue = model.value
  }
}

struct ModelPickerModelItem: Identifiable {
  let group: ModelMenuGroup
  let model: SessionConfigSelectOption

  var id: ModelPickerKeyboardTarget {
    .model(groupID: group.id, value: model.value)
  }
}

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
      return ModelPickerModelItem(group: group, model: model)
    }
  }

  var regularGroups: [ModelMenuGroup] {
    groups.filter { !regularModels(in: $0).isEmpty }
  }

  var sectionItemCounts: [Int] {
    var counts = favorites.isEmpty ? [] : [favorites.count]
    counts.append(contentsOf: regularGroups.map { regularModels(in: $0).count })
    return counts
  }

  func regularModels(in group: ModelMenuGroup) -> [SessionConfigSelectOption] {
    group.matchingModels(query: query).filter {
      !favoriteSet.contains(ModelPickerFavorite(model: $0, group: group))
    }
  }
}

enum ModelPickerFavoriteAction {
  case add
  case remove

  var symbolName: String {
    switch self {
    case .add: "star"
    case .remove: "star.slash"
    }
  }

  var label: String {
    switch self {
    case .add: "Add to Favorites"
    case .remove: "Remove from Favorites"
    }
  }
}
