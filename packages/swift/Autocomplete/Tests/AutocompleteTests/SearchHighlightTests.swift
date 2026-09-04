import Testing
@testable import Autocomplete

@Suite("Autocomplete search highlight")
@MainActor
struct SearchHighlightTests {
  private let targets = ["first", "second", "third"]

  @Test("Starting a search highlights its first result and Return accepts it")
  func searchStartsAtFirstResult() {
    let highlight = Autocomplete.Highlight<String>(navigation: .menu)
    highlight.reconcile(with: targets, query: "")
    #expect(highlight.highlighted == nil)
    highlight.hover("third")

    highlight.reconcile(with: ["first", "second"], query: "match")

    #expect(highlight.highlighted == "first")
    #expect(highlight.source == .keyboard)
    var accepted: String?
    highlight.handle(.accept, targets: ["first", "second"], accept: { accepted = $0 }, dismiss: {})
    #expect(accepted == "first")
  }

  @Test("Editing search returns to the first result even when the same rows match")
  func queryChangesWithIdenticalResults() {
    let highlight = Autocomplete.Highlight<String>(navigation: .menu)
    highlight.reconcile(with: targets, query: "m")
    highlight.moveToLast(in: targets)

    highlight.reconcile(with: targets, query: "ma")

    #expect(highlight.highlighted == "first")
    #expect(!highlight.navigation.loop)
  }

  @Test("An unchanged search preserves keyboard and pointer choices")
  func unchangedSearch() {
    let highlight = Autocomplete.Highlight<String>(navigation: .menu)
    highlight.reconcile(with: targets, query: "match")
    highlight.move(by: 1, in: targets)
    highlight.reconcile(with: targets, query: "match")
    #expect(highlight.highlighted == "second")

    highlight.hover("third")
    highlight.endHover("third")
    highlight.reconcile(with: targets, query: "match")
    #expect(highlight.highlighted == "third")
    #expect(highlight.source == .pointer)
  }

  @Test("Clearing search restores an unhighlighted menu", arguments: ["", " \n\t"])
  func clearingSearch(query: String) {
    let highlight = Autocomplete.Highlight<String>(navigation: .menu)
    highlight.reconcile(with: targets, query: "match")
    highlight.reconcile(with: targets, query: query)
    #expect(highlight.highlighted == nil)

    highlight.hover("second")
    highlight.endHover("second")
    #expect(highlight.highlighted == nil)
  }

  @Test("No matches clears the highlight and arriving results seed the first item")
  func emptyThenArrivingResults() {
    let highlight = Autocomplete.Highlight<String>(navigation: .menu)
    highlight.reconcile(with: targets, query: "match")
    highlight.reconcile(with: [], query: "missing")
    #expect(highlight.highlighted == nil)
    #expect(
      !highlight.handle(.accept, targets: [], accept: { _ in Issue.record("Accepted an empty result") }, dismiss: {}))

    highlight.reconcile(with: ["second", "third"], query: "missing")
    #expect(highlight.highlighted == "second")
  }

  @Test("Clearing an inline search retains its auto-highlight preset")
  func inlineSearch() {
    let highlight = Autocomplete.Highlight<String>(navigation: .inline)
    highlight.reconcile(with: targets, query: "match")
    highlight.moveToLast(in: targets)
    highlight.reconcile(with: targets, query: "")
    #expect(highlight.highlighted == "first")
    #expect(highlight.navigation.loop)
  }

  @Test("Reopening a menu forgets the previous search")
  func resetSearch() {
    let highlight = Autocomplete.Highlight<String>(navigation: .menu)
    highlight.reconcile(with: targets, query: "match")
    highlight.reset()
    highlight.reconcile(with: targets, query: "")
    #expect(highlight.highlighted == nil)
    #expect(highlight.source == nil)
  }
}
