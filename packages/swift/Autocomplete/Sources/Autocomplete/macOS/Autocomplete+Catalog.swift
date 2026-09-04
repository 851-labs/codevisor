#if canImport(AppKit)
  import SwiftUI

  extension Autocomplete {
    enum NodeID: Hashable {
      case section([AnyHashable])
      case item([AnyHashable], AnyHashable)
      case heading(NodeIDBox)
      case separator(NodeIDBox)
      case favorites
    }

    /// Indirection for decorative IDs without string sentinels or collisions
    /// with caller-provided values.
    struct NodeIDBox: Hashable { let value: AnyHashable }
    private struct RunID: Hashable { let index: Int }

    struct CatalogItem: Identifiable {
      let id: NodeID
      let definition: ItemDefinition
      let searchTerms: [String]
      let normalizedTerms: [String]
    }

    struct CatalogSection: Identifiable {
      let id: NodeID
      let title: String?
      let items: [CatalogItem]
    }

    @MainActor
    struct Catalog {
      let revision = UUID()
      let sections: [CatalogSection]
      let items: [CatalogItem]
      let showsIcons: Bool
      let showsCheckmarks: Bool
      let titles: [String]
      let shortcuts: [KeyboardShortcut]
      let maximumAccessoryCount: Int
      let unfiltered: Snapshot

      init(_ entries: [Entry], locale: Locale = .current) {
        var sections: [CatalogSection] = []
        func visit(_ entries: [Entry], path: [AnyHashable], title: String?) {
          var run: [CatalogItem] = []
          var runIndex = 0
          func flush() {
            guard !run.isEmpty else { return }
            let id = NodeID.section(path + [AnyHashable(RunID(index: runIndex))])
            sections.append(CatalogSection(id: id, title: title, items: run))
            run.removeAll(keepingCapacity: true)
            runIndex += 1
          }
          for entry in entries {
            switch entry.kind {
            case let .item(definition):
              let terms = [definition.title] + definition.keywords + (title.map { [$0] } ?? [])
              run.append(
                CatalogItem(
                  id: .item(path, definition.id), definition: definition,
                  searchTerms: terms, normalizedTerms: terms.map { Filter.normalized($0, locale: locale) }))
            case let .section(id, title, children):
              flush()
              visit(children, path: path + [id], title: title)
            }
          }
          flush()
        }
        visit(entries, path: [], title: nil)
        self.sections = sections
        items = sections.flatMap(\.items)
        assert(
          Set(items.map(\.id)).count == items.count, "Autocomplete choice/action IDs must be unique within their scope")
        assert(
          Set(sections.map(\.id)).count == sections.count, "Autocomplete section IDs must be unique within their scope")
        showsIcons = items.contains { $0.definition.icon != nil }
        showsCheckmarks = items.contains { $0.definition.isChoice }
        titles = items.map { $0.definition.title } + sections.compactMap(\.title)
        shortcuts = items.compactMap { $0.definition.shortcut }
        maximumAccessoryCount = items.map { $0.definition.secondaryActions.count }.max() ?? 0
        unfiltered = Self.snapshot(sections)
      }

      func results(query: String, filter: Filter, locale: Locale = .current) -> Snapshot {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return unfiltered }
        let normalizedQuery = Filter.normalized(query, locale: locale)
        let matching = sections.compactMap { section -> CatalogSection? in
          let items = section.items.filter { item in
            zip(item.normalizedTerms, item.searchTerms).contains {
              filter.matchesPrepared($0.0, original: $0.1, query: normalizedQuery, originalQuery: query)
            }
          }
          return items.isEmpty ? nil : CatalogSection(id: section.id, title: section.title, items: items)
        }
        return Self.snapshot(matching)
      }

      private static func snapshot(_ matching: [CatalogSection]) -> Snapshot {
        let favorites = matching.flatMap(\.items).enumerated()
          .filter { $0.element.definition.favoriteOrder != nil }
          .sorted {
            let lhs = $0.element.definition.favoriteOrder ?? 0
            let rhs = $1.element.definition.favoriteOrder ?? 0
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
          }.map(\.element)
        guard !favorites.isEmpty else { return Snapshot(sections: matching) }
        let favoriteIDs = Set(favorites.map(\.id))
        let regular = matching.compactMap { section -> CatalogSection? in
          let items = section.items.filter { !favoriteIDs.contains($0.id) }
          return items.isEmpty ? nil : CatalogSection(id: section.id, title: section.title, items: items)
        }
        return Snapshot(sections: [CatalogSection(id: .favorites, title: nil, items: favorites)] + regular)
      }
    }

    struct PresentationRow: Identifiable {
      enum Kind { case heading(String), separator, item(CatalogItem) }
      let id: NodeID
      let kind: Kind
    }

    @MainActor
    struct Snapshot {
      let sections: [CatalogSection]
      let items: [CatalogItem]
      let eligibleIDs: [NodeID]
      let byID: [NodeID: CatalogItem]
      let rows: [PresentationRow]

      init(sections: [CatalogSection] = []) {
        self.sections = sections
        items = sections.flatMap(\.items)
        eligibleIDs = items.filter { !$0.definition.isDisabled }.map(\.id)
        byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = sections.enumerated().flatMap { index, section -> [PresentationRow] in
          var rows: [PresentationRow] = []
          let box = NodeIDBox(value: AnyHashable(section.id))
          if index > 0 { rows.append(.init(id: .separator(box), kind: .separator)) }
          if let title = section.title { rows.append(.init(id: .heading(box), kind: .heading(title))) }
          rows.append(contentsOf: section.items.map { .init(id: $0.id, kind: .item($0)) })
          return rows
        }
      }

      func listHeight(metrics: Metrics, dividers: Bool) -> CGFloat {
        max(
          metrics.emptyListHeight,
          metrics.listHeight(
            itemCount: items.count, groupLabelCount: sections.filter { $0.title != nil }.count,
            dividerCount: dividers ? max(sections.count - 1, 0) : 0))
      }
    }

    /// Memoization only: never publishes during a view update. Search edits
    /// reuse title measurements; a content/font/column change invalidates them.
    @MainActor
    final class Measurements {
      private var key: Key?
      private var width: CGFloat = 0
      private(set) var measurementCount = 0

      private struct Key: Equatable {
        let titles: [String]
        let shortcuts: [String]
        let metrics: Metrics
        let icons: Bool
        let checks: Bool
        let accessoryCount: Int
      }

      func popupWidth(catalog: Catalog, metrics: Metrics) -> CGFloat {
        let next = Key(
          titles: catalog.titles, shortcuts: catalog.shortcuts.map(Autocomplete.symbols),
          metrics: metrics, icons: catalog.showsIcons, checks: catalog.showsCheckmarks,
          accessoryCount: catalog.maximumAccessoryCount)
        if key != next {
          width = metrics.popupWidth(
            fitting: catalog.titles, hasIcons: catalog.showsIcons,
            showsCheckmarks: catalog.showsCheckmarks, shortcuts: catalog.shortcuts,
            accessoryCount: catalog.maximumAccessoryCount)
          key = next
          measurementCount += 1
        }
        return width
      }
    }
  }
#endif
