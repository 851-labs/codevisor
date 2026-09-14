#if canImport(AppKit)
  import SwiftUI
  import Testing
  @testable import Autocomplete

  @Suite("Autocomplete footers")
  @MainActor
  struct FooterTests {
    private let locale = Locale(identifier: "en_US_POSIX")

    @Test("Management actions stay outside filtered results and remain visible without matches")
    func filtering() {
      let entries = Autocomplete.ContentBuilder.buildBlock(
        Autocomplete.Picker("Projects", selection: .constant("A")) {
          Autocomplete.Choice("Alpha", value: "A")
          Autocomplete.Choice("Beta", value: "B")
        }.autocompleteEntries,
        Autocomplete.Footer(id: "manage") {
          Autocomplete.Action("Manage projects…") {}
        }.autocompleteEntries)
      let catalog = Autocomplete.Catalog(entries, locale: locale)
      let footerID = catalog.unfiltered.footerItems.first?.id
      for (query, expected) in [("", ["Alpha", "Beta"]), ("alpha", ["Alpha"]), ("missing", []), ("manage", [])] {
        let snapshot = catalog.results(query: query, filter: .contains, locale: locale)
        #expect(snapshot.resultItems.map { $0.definition.title } == expected)
        #expect(snapshot.footerItems.map { $0.definition.title } == ["Manage projects…"])
        #expect(snapshot.footerItems.first?.id == footerID)
        #expect(snapshot.eligibleIDs.last == footerID)
        #expect(!snapshot.rows.contains { $0.id == footerID })
      }
    }

    @Test("Footers follow favorites and choices without contributing to result height")
    func layoutAndOrder() {
      let entries = Autocomplete.ContentBuilder.buildBlock(
        Autocomplete.Footer(id: "manage") {
          Autocomplete.Action("Manage") {}
        }.autocompleteEntries,
        Autocomplete.Picker("Projects", selection: .constant("A")) {
          Autocomplete.Choice("Alpha", value: "A")
          Autocomplete.Choice("Beta", value: "B")
        }.favorites(.constant(["B"])).labelsHidden().autocompleteEntries)
      let snapshot = Autocomplete.Catalog(entries, locale: locale).unfiltered
      #expect(snapshot.items.map { $0.definition.title } == ["Beta", "Alpha", "Manage"])
      let withoutFooter = Autocomplete.Snapshot(sections: snapshot.sections)
      let metrics = Autocomplete.Metrics.xcodeMenu
      #expect(
        snapshot.listHeight(metrics: metrics, dividers: true)
          == withoutFooter.listHeight(metrics: metrics, dividers: true))
      #expect(
        snapshot.footerHeight(metrics: metrics, dividers: true) == 1 + metrics.itemHeight + 2
          * metrics.listVerticalInset)
      #expect(withoutFooter.footerHeight(metrics: metrics, dividers: true) == 0)
    }

    @Test("Keyboard navigation reaches the footer after results and activates it once with dismissal")
    func keyboardActivation() {
      var activations = 0
      var dismissals = 0
      let entries = Autocomplete.ContentBuilder.buildBlock(
        Autocomplete.Action("Alpha") { Issue.record("Result was activated") }.autocompleteEntries,
        Autocomplete.Footer(id: "manage") {
          Autocomplete.Action("Manage") { activations += 1 }
        }.autocompleteEntries)
      let catalog = Autocomplete.Catalog(entries, locale: locale)
      let host = Autocomplete.Host()
      defer { host.stop() }
      host.dismissOnSelection = true
      host.dismiss = {
        dismissals += 1; return true
      }
      host.update(snapshot: catalog.unfiltered, query: "", isEnabled: true, navigation: .menu)
      #expect(host.handle(.moveDown))
      #expect(host.highlight.highlighted == catalog.unfiltered.resultItems.first?.id)
      #expect(host.handle(.moveDown))
      #expect(host.highlight.highlighted == catalog.unfiltered.footerItems.first?.id)
      #expect(host.handle(.accept))
      #expect(activations == 1)
      #expect(dismissals == 1)

      let empty = catalog.results(query: "missing", filter: .contains, locale: locale)
      host.update(snapshot: empty, query: "missing", isEnabled: true, navigation: .menu)
      #expect(host.handle(.accept))
      #expect(activations == 2)
      #expect(dismissals == 2)
      host.update(snapshot: empty, query: "missing", isEnabled: false, navigation: .menu)
      #expect(!host.handle(.accept))
      #expect(activations == 2)
    }

    @Test("Disabling a footer or its parent keeps actions visible but ineligible")
    func disabledFooter() {
      let footer = Autocomplete.Footer(id: "manage") {
        Autocomplete.Section("Settings") {
          Autocomplete.Action("Manage") { Issue.record("Disabled footer ran") }
        }
      }
      let parent = Autocomplete.Section("Parent") { footer }.disabled()
      for entries in [footer.disabled().autocompleteEntries, parent.autocompleteEntries] {
        let snapshot = Autocomplete.Catalog(entries, locale: locale).results(
          query: "missing", filter: .contains, locale: locale)
        #expect(snapshot.footerItems.count == 1)
        #expect(snapshot.eligibleIDs.isEmpty)
        #expect(snapshot.resultItems.isEmpty)
      }
    }
  }
#endif
