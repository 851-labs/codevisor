import Testing
@testable import Autocomplete

@Suite("Autocomplete results")
struct ResultsTests {
  private struct Candidate: Identifiable {
    let id: String
    let title: String
    var keywords: [String] = []
  }

  private var sections: [Autocomplete.Section<Candidate>] {
    [
      .init(
        id: "projects", title: "Projects",
        items: [
          Candidate(id: "none", title: "No project"),
          Candidate(id: "codevisor", title: "Codevisor", keywords: ["Résumé"]),
        ]),
      .init(id: "actions", items: [Candidate(id: "new", title: "New Project…")]),
    ]
  }

  private func results(_ query: String, filter: Autocomplete.Filter = .contains) -> Autocomplete.Results<Candidate> {
    Autocomplete.Results(sections: sections, query: query, filter: filter) { [$0.title] + $0.keywords }
  }

  @Test("An action-only match has no empty state, heading, or leading divider")
  func actionOnly() {
    let results = results("new")
    #expect(results.items.map(\.id) == ["new"])
    #expect(!results.isEmpty)
    #expect(results.sections.map(\.id) == ["actions"])
    #expect(results.groupLabelCount == 0)
    #expect(results.dividerCount == 0)
  }

  @Test("Unmatched actions disappear alongside unmatched choices")
  func choiceOnly() {
    let results = results("codevisor")
    #expect(results.items.map(\.id) == ["codevisor"])
    #expect(results.sections.map(\.title) == ["Projects"])
    #expect(results.dividerCount == 0)
  }

  @Test("Nothing matching produces only an empty state")
  func noMatches() {
    let results = results("does not exist")
    #expect(results.isEmpty)
    #expect(results.itemCount == 0)
    #expect(results.groupLabelCount == 0)
    #expect(results.dividerCount == 0)
  }

  @Test("A query can match both choices and commands in their original order")
  func choicesAndCommands() {
    let results = results("project")
    #expect(results.items.map(\.id) == ["none", "new"])
    #expect(results.dividerCount == 1)
    #expect(results.groupLabelCount == 1)
  }

  @Test("Empty and whitespace-only queries show the whole collection", arguments: ["", " \n\t "])
  func emptyQuery(query: String) {
    let results = results(query)
    #expect(results.items.map(\.id) == ["none", "codevisor", "new"])
    #expect(results.dividerCount == 1)
  }

  @Test("Queries are trimmed and matching ignores case and diacritics")
  func normalization() {
    #expect(results("  NEW\n").items.map(\.id) == ["new"])
    #expect(results("resume").items.map(\.id) == ["codevisor"])
  }

  @Test("Custom filter presets apply to commands too")
  func customFilter() {
    #expect(results("np", filter: .subsequence).items.map(\.id) == ["none", "new"])
    #expect(results("project", filter: .startsWith).isEmpty)
  }

  @Test("Empty sections never contribute headings or extra separators")
  func emptySections() {
    let sections = [
      Autocomplete.Section<Candidate>(id: "empty-start", title: "Start", items: []),
      self.sections[0],
      .init(id: "empty-middle", title: "Middle", items: []),
      self.sections[1],
      .init(id: "empty-end", title: "End", items: []),
    ]
    let results = Autocomplete.Results(sections: sections) { [$0.title] }
    #expect(results.sections.map(\.id) == ["projects", "actions"])
    #expect(results.dividerCount == 1)
    #expect(results.groupLabelCount == 1)
  }

  @Test("Filtering reconciles keyboard targets and Return accepts the action")
  @MainActor
  func navigationFollowsResults() {
    let highlight = Autocomplete.Highlight<String>(navigation: .menu)
    highlight.hover("codevisor")
    let actionTargets = results("new").items.map(\.id)
    highlight.reconcile(with: actionTargets, query: "new")
    #expect(highlight.highlighted == "new")
    var accepted: String?
    highlight.handle(.accept, targets: actionTargets, accept: { accepted = $0 }, dismiss: {})
    #expect(accepted == "new")

    let emptyTargets = results("missing").items.map(\.id)
    highlight.reconcile(with: emptyTargets, query: "missing")
    #expect(highlight.highlighted == nil)
    #expect(
      !highlight.handle(
        .accept, targets: emptyTargets, accept: { _ in Issue.record("Accepted a hidden row") }, dismiss: {}))

    let restoredTargets = results("").items.map(\.id)
    highlight.reconcile(with: restoredTargets, query: "")
    #expect(highlight.highlighted == nil)
    highlight.move(by: 1, in: restoredTargets)
    #expect(highlight.highlighted == "none")
  }

  #if canImport(AppKit)
    @Test("Menu sizing counts visible section chrome and fits the empty state")
    func menuSizing() {
      let metrics = Autocomplete.Metrics.xcodeMenu
      let catalog = results("")
      let content = metrics.listContentHeight(
        itemCount: 3, groupLabelCount: 1, dividerCount: 1, groupSpacingCount: 0
      )
      #expect(metrics.listHeight(for: catalog) == content)
      #expect(
        Double(metrics.listHeight(for: catalog, showsSectionDividers: false)) == Double(content - metrics.dividerHeight)
      )
      #expect(metrics.listHeight(for: results("new")) == metrics.emptyListHeight)
      #expect(metrics.listHeight(for: results("missing")) == metrics.emptyListHeight)

      let manyItems = (0..<100).map { Candidate(id: "\($0)", title: "Item \($0)") }
      let longResults = Autocomplete.Results(sections: [.init(id: "long", items: manyItems)]) { [$0.title] }
      let inputHeight = metrics.inputTopInset + metrics.inputHeight + metrics.inputBottomInset
      let maximumListHeight = metrics.maximumHeight - inputHeight
      #expect(Double(metrics.listHeight(for: longResults)) == Double(maximumListHeight))
    }
  #endif
}
