#if canImport(AppKit)
  import Observation
  import SwiftUI
  import Testing
  @testable import Autocomplete

  @MainActor
  @Observable
  final class SelectionStore<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
    var binding: Binding<Value> { Binding(get: { self.value }, set: { self.value = $0 }) }
  }

  @Suite("Autocomplete semantic catalog")
  @MainActor
  struct CatalogTests {
    private var locale: Locale { Locale(identifier: "en_US_POSIX") }
    private func catalog(@Autocomplete.ContentBuilder _ content: () -> [Autocomplete.Entry]) -> Autocomplete.Catalog {
      Autocomplete.Catalog(content(), locale: locale)
    }
    private func titles(_ snapshot: Autocomplete.Snapshot) -> [String] { snapshot.items.map { $0.definition.title } }

    @Test("Disabling a section includes nested choices, commands, and their secondary actions")
    func disabledSection() {
      let catalog = catalog {
        Autocomplete.Section("Outer") {
          Autocomplete.Action("Command") {}
          Autocomplete.Picker("Nested", selection: .constant(1)) {
            Autocomplete.Choice("Choice", value: 1).disabled(false)
          }
        }.disabled()
      }
      #expect(catalog.unfiltered.items.count == 2)
      #expect(catalog.unfiltered.eligibleIDs.isEmpty)
    }

    @Test("Package announcements use localized count plurals and spoken keys")
    func localizedAnnouncements() {
      #expect(Autocomplete.Strings.resultCount(0) == "0 results")
      #expect(Autocomplete.Strings.resultCount(1) == "1 result")
      #expect(Autocomplete.Strings.resultCount(2) == "2 results")
      #expect(Autocomplete.Strings.position(1, count: 2) == "1 of 2")
      #expect(Autocomplete.accessibilityDescription(for: KeyboardShortcut(.return, modifiers: [])) == "Return")
    }

    @Test("Highlight and layout updates reuse filtering; query, filter, and content changes invalidate it")
    func resultCache() {
      let prepared = Autocomplete.PreparedCatalog()
      let catalog = catalog {
        Autocomplete.Action("Alpha") {}; Autocomplete.Action("Beta") {}
      }
      for _ in 0..<10 {
        _ = prepared.results(catalog: catalog, query: "a", filter: .contains, locale: locale)
      }
      #expect(prepared.filterCount == 1)
      let prefixed = prepared.results(catalog: catalog, query: "a", filter: .startsWith, locale: locale)
      #expect(titles(prefixed) == ["Alpha"])
      #expect(prepared.filterCount == 2)
      let changed = self.catalog { Autocomplete.Action("Another") {} }
      #expect(
        titles(prepared.results(catalog: changed, query: "a", filter: .startsWith, locale: locale)) == ["Another"])
      #expect(prepared.filterCount == 3)
      _ = prepared.results(catalog: changed, query: "n", filter: .contains, locale: locale)
      #expect(prepared.filterCount == 4)
    }

    @Test("Selection bindings derive checkmarks and receive the chosen value")
    func selection() {
      let selection = SelectionStore("High")
      let catalog = catalog {
        Autocomplete.Picker("Effort", selection: selection.binding) {
          ForEach(["Low", "High"], id: \.self) { Autocomplete.Choice($0, value: $0) }
        }
      }
      #expect(catalog.showsCheckmarks)
      #expect(catalog.items.map { $0.definition.isSelected } == [false, true])
      catalog.items[0].definition.perform()
      #expect(selection.value == "Low")
    }

    @Test("Multiple pickers may reuse values without sharing selection or identity")
    func independentPickers() {
      let first = SelectionStore("A")
      let second = SelectionStore("B")
      let catalog = catalog {
        Autocomplete.Picker("First", selection: first.binding) { Autocomplete.Choice("A", value: "A") }
        Autocomplete.Picker("Second", selection: second.binding) { Autocomplete.Choice("A", value: "A") }
      }
      #expect(catalog.items[0].id != catalog.items[1].id)
      catalog.items[1].definition.perform()
      #expect(first.value == "A")
      #expect(second.value == "A")
    }

    @Test("ForEach, conditionals, and loops produce the complete semantic collection")
    func composition() {
      let include = true
      let catalog = catalog {
        if include { Autocomplete.Action("First") {} }
        for number in [2, 3] { Autocomplete.Action("Item \(number)", id: number) {} }
        ForEach(["Fourth", "Fifth"], id: \.self) { Autocomplete.Action($0) {} }
        if !include { Autocomplete.Action("Hidden") {} }
      }
      #expect(titles(catalog.unfiltered) == ["First", "Item 2", "Item 3", "Fourth", "Fifth"])
    }

    @Test("Action-only matching removes unrelated headings and empty state")
    func actionOnly() {
      let catalog = catalog {
        Autocomplete.Section("Projects") { Autocomplete.Action("Codevisor") {} }
        Autocomplete.Section(id: "actions") { Autocomplete.Action("New Project…") {} }
      }
      let result = catalog.results(query: "new", filter: .contains, locale: locale)
      #expect(titles(result) == ["New Project…"])
      #expect(result.sections.count == 1)
      #expect(result.sections[0].title == nil)
      #expect(catalog.results(query: "missing", filter: .contains, locale: locale).items.isEmpty)
    }

    @Test("Group titles, explicit keywords, and Unicode normalization participate in search")
    func searchTerms() {
      let selection = SelectionStore("a")
      let catalog = catalog {
        Autocomplete.Picker("Models", selection: selection.binding) {
          Autocomplete.Choice("Résumé", value: "a").searchTerms(["document"])
          Autocomplete.Choice("Sonnet", value: "b")
        }
      }
      #expect(titles(catalog.results(query: " MODELS\n", filter: .contains, locale: locale)) == ["Résumé", "Sonnet"])
      #expect(titles(catalog.results(query: "resume", filter: .contains, locale: locale)) == ["Résumé"])
      #expect(titles(catalog.results(query: "rsm", filter: .subsequence, locale: locale)) == ["Résumé"])
      #expect(titles(catalog.results(query: "doc", filter: .startsWith, locale: locale)) == ["Résumé"])
      #expect(catalog.results(query: " \n\t", filter: .contains, locale: locale).items.count == 2)
    }

    @Test("Custom filters receive original text")
    func customFilter() {
      let catalog = catalog { Autocomplete.Action("Résumé") {} }
      let filter = Autocomplete.Filter { candidate, query in candidate == "Résumé" && query == "custom" }
      #expect(catalog.results(query: "custom", filter: filter, locale: locale).items.count == 1)
    }

    @Test("Empty sections have no heading or separator identity")
    func emptySections() {
      let catalog = catalog {
        Autocomplete.Section("Empty") {}
        Autocomplete.Section("Visible") { Autocomplete.Action("One") {} }
        Autocomplete.Section("Empty end") {}
      }
      #expect(catalog.unfiltered.sections.map(\.title) == ["Visible"])
    }

    @Test("Favorites preserve stored order and deduplicate stale stored values")
    func favorites() {
      let selection = SelectionStore("a")
      let favorites = SelectionStore(["missing", "b", "b", "a"])
      let catalog = catalog {
        Autocomplete.Picker("Choices", selection: selection.binding) {
          Autocomplete.Choice("A", value: "a")
          Autocomplete.Choice("B", value: "b")
          Autocomplete.Choice("C", value: "c")
        }.favorites(favorites.binding)
        Autocomplete.Section(id: "actions") { Autocomplete.Action("Manage") {} }
      }
      #expect(titles(catalog.unfiltered) == ["B", "A", "C", "Manage"])
      #expect(catalog.unfiltered.sections[0].id == .favorites)
      #expect(catalog.unfiltered.sections[0].title == nil)
      #expect(favorites.value == ["missing", "b", "b", "a"])
      #expect(titles(catalog.results(query: "manage", filter: .contains, locale: locale)) == ["Manage"])
    }

    @Test("No selection is a real favoritable value, not an identity sentinel")
    func optionalFavorite() {
      let selection = SelectionStore<String?>(nil)
      let favorites = SelectionStore<[String?]>([nil])
      let catalog = catalog {
        Autocomplete.Picker("Project", selection: selection.binding) {
          Autocomplete.Choice("No project", value: Optional<String>.none)
          Autocomplete.Choice("Codevisor", value: Optional("codevisor"))
        }.favorites(favorites.binding)
      }
      let none = catalog.unfiltered.items[0]
      #expect(none.definition.isSelected)
      #expect(none.definition.favoriteOrder == 0)
      none.definition.secondaryActions[0].perform()
      #expect(favorites.value.isEmpty)
      #expect(selection.value == nil)
    }

    @Test("Ineligible favorites stay in storage and keep their normal position")
    func ineligibleFavorite() {
      let selection = SelectionStore("a")
      let favorites = SelectionStore(["b"])
      let catalog = catalog {
        Autocomplete.Picker("Choices", selection: selection.binding) {
          Autocomplete.Choice("A", value: "a")
          Autocomplete.Choice("B", value: "b").favoritable(false)
        }.favorites(favorites.binding)
      }
      #expect(titles(catalog.unfiltered) == ["A", "B"])
      #expect(catalog.items[1].definition.secondaryActions.isEmpty)
      #expect(favorites.value == ["b"])
    }

    @Test("Favorite promotion keeps item identities stable across sections and queries")
    func identity() {
      let selection = SelectionStore("a")
      let favorites = SelectionStore(["b"])
      func make() -> Autocomplete.Catalog {
        catalog {
          Autocomplete.Picker("Choices", selection: selection.binding) {
            Autocomplete.Choice("A", value: "a")
            Autocomplete.Choice("B", value: "b")
          }.favorites(favorites.binding)
        }
      }
      let before = make()
      let id = before.unfiltered.items.first!.id
      favorites.value = []
      let after = make()
      #expect(after.items.last?.id == id)
      #expect(after.results(query: "b", filter: .contains, locale: locale).items.first?.id == id)
    }

    @Test("Cache reuses width across query edits and updates for metrics and new titles")
    func measurementCache() {
      let first = catalog { Autocomplete.Action("First") {} }
      let cache = Autocomplete.Measurements()
      var metrics = Autocomplete.Metrics()
      let width = cache.popupWidth(catalog: first, metrics: metrics)
      _ = first.results(query: "f", filter: .contains, locale: locale)
      #expect(cache.popupWidth(catalog: first, metrics: metrics) == width)
      #expect(cache.measurementCount == 1)
      let sameTitles = catalog { Autocomplete.Action("First") {} }
      _ = cache.popupWidth(catalog: sameTitles, metrics: metrics)
      #expect(cache.measurementCount == 1)
      metrics.fontSize = 24
      _ = cache.popupWidth(catalog: first, metrics: metrics)
      #expect(cache.measurementCount == 2)
      let changed = catalog { Autocomplete.Action("A much longer title") {} }
      _ = cache.popupWidth(catalog: changed, metrics: metrics)
      #expect(cache.measurementCount == 3)
    }

    @Test("Custom labels retain explicit search and accessibility text")
    func richLabel() {
      let catalog = catalog {
        Autocomplete.Action("Open plugin", id: "plugin", action: {}) {
          Image(systemName: "puzzlepiece")
        } label: {
          HStack {
            Text("Plugin"); Text("Beta")
          }
        }
      }
      #expect(catalog.showsIcons)
      #expect(catalog.items.first?.definition.label != nil)
      #expect(titles(catalog.results(query: "open", filter: .contains, locale: locale)) == ["Open plugin"])
    }
  }
#endif
