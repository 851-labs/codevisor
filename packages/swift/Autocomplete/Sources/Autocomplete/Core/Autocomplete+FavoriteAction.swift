extension Autocomplete {
  /// The shared label and glyph for a row's favorite toggle.
  enum FavoriteAction: Sendable, Hashable {
    case add
    case remove

    init(isFavorite: Bool) {
      self = isFavorite ? .remove : .add
    }

    var symbolName: String {
      switch self {
      case .add: "star"
      case .remove: "star.slash"
      }
    }

    var label: String {
      switch self {
      case .add: Strings.text("Add to Favorites")
      case .remove: Strings.text("Remove from Favorites")
      }
    }
  }
}
