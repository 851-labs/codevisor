import Foundation

public extension Autocomplete {
  /// A run of options, optionally headed by a title. Section IDs and item IDs
  /// must be stable; item IDs must be unique across the whole menu.
  struct Section<Element: Identifiable>: Identifiable {
    public let id: String
    public let title: String?
    public let items: [Element]

    public init(id: String, title: String? = nil, items: [Element]) {
      self.id = id
      self.title = title
      self.items = items
    }
  }

  /// One filtered collection drives the rows, favorites, headings, separators,
  /// empty state, and layout. Commands and choices follow the same matching rules.
  struct Results<Element: Identifiable> {
    public let sections: [Section<Element>]

    public init(
      sections: [Section<Element>],
      query: String = "",
      filter: Filter = .contains,
      favoriteIDs: [Element.ID] = [],
      isFavoritable: (Element) -> Bool = { _ in true },
      searchTerms: (Element) -> [String]
    ) {
      let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
      let matchingSections = sections.compactMap { section -> Section<Element>? in
        let items = section.items.filter { item in
          query.isEmpty || searchTerms(item).contains { filter.matches($0, query: query) }
        }
        guard !items.isEmpty else { return nil }
        return Section(id: section.id, title: section.title, items: items)
      }
      var candidates: [Element.ID: Element] = [:]
      for item in matchingSections.flatMap(\.items) where isFavoritable(item) {
        candidates[item.id] = item
      }
      // Stored order is the order items were starred. Missing IDs stay in
      // the caller's storage; duplicate IDs must never produce duplicate rows.
      let favorites = favoriteIDs.compactMap { candidates.removeValue(forKey: $0) }
      guard !favorites.isEmpty else {
        self.sections = matchingSections
        return
      }
      let favoriteSet = Set(favorites.map(\.id))
      var favoritesSectionID = "autocomplete:favorites"
      while sections.contains(where: { $0.id == favoritesSectionID }) {
        favoritesSectionID += ":"
      }
      self.sections =
        [Section(id: favoritesSectionID, items: favorites)]
        + matchingSections.compactMap { section in
          let items = section.items.filter { !favoriteSet.contains($0.id) }
          guard !items.isEmpty else { return nil }
          return Section(id: section.id, title: section.title, items: items)
        }
    }

    public var items: [Element] { sections.flatMap(\.items) }
    public var isEmpty: Bool { sections.isEmpty }
    public var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }
    public var groupLabelCount: Int { sections.filter { $0.title != nil }.count }
    public var dividerCount: Int { max(sections.count - 1, 0) }
  }
}
