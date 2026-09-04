import ACPKit

/// Domain choices and persisted identity; filtering and grouping live in Autocomplete.
struct ModelMenuGroup: Identifiable {
  let id: String
  let name: String
  let symbolName: String
  let modelOption: SessionConfigOption
}

struct ModelPickerFavorite: Codable, Hashable {
  let harnessID: String
  let modelValue: String

  init(harnessID: String, modelValue: String) {
    self.harnessID = harnessID
    self.modelValue = modelValue
  }

  init(model: SessionConfigSelectOption, group: ModelMenuGroup) {
    harnessID = group.id
    modelValue = model.value
  }
}
