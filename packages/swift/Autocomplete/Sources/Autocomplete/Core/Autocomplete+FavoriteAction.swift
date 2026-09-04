public extension Autocomplete {
  /// The shared label and glyph for a row's favorite toggle.
  enum FavoriteAction: Sendable, Hashable {
    case add
    case remove

    public init(isFavorite: Bool) {
      self = isFavorite ? .remove : .add
    }

    public var symbolName: String {
      switch self {
      case .add: "star"
      case .remove: "star.slash"
      }
    }

    public var label: String {
      switch self {
      case .add: "Add to Favorites"
      case .remove: "Remove from Favorites"
      }
    }
  }
}
