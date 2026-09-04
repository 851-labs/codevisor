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

  /// One filtered collection drives the rows, headings, separators, empty
  /// state, and layout. Commands and choices follow the same matching rules.
  struct Results<Element: Identifiable> {
    public let sections: [Section<Element>]

    public init(
      sections: [Section<Element>],
      query: String = "",
      filter: Filter = .contains,
      searchTerms: (Element) -> [String]
    ) {
      let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
      self.sections = sections.compactMap { section in
        let items = section.items.filter { item in
          query.isEmpty || searchTerms(item).contains { filter.matches($0, query: query) }
        }
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
