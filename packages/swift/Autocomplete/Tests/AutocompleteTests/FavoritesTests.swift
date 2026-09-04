import Testing
@testable import Autocomplete

@Suite("Autocomplete favorites")
struct FavoritesTests {
  private struct Candidate: Identifiable {
    let id: String
    let title: String
    var isFavoritable = true
  }

  private var sections: [Autocomplete.Section<Candidate>] {
    [
      .init(
        id: "projects",
        items: [
          Candidate(id: "none", title: "No project"),
          Candidate(id: "codevisor", title: "Codevisor"),
          Candidate(id: "pixelbook", title: "PixelBook"),
        ]),
      .init(
        id: "actions",
        items: [Candidate(id: "new", title: "New Project…", isFavoritable: false)]),
    ]
  }

  private func results(
    favorites: [String], query: String = "", sections: [Autocomplete.Section<Candidate>]? = nil
  ) -> Autocomplete.Results<Candidate> {
    Autocomplete.Results(
      sections: sections ?? self.sections, query: query,
      favoriteIDs: favorites, isFavoritable: \.isFavoritable
    ) { [$0.title] }
  }

  @Test("Favorites lead in saved order without duplicating choices or moving commands")
  func savedOrder() {
    let result = results(favorites: ["pixelbook", "codevisor"])
    #expect(result.sections.map(\.title) == [nil, nil, nil])
    #expect(result.sections.map { $0.items.map(\.id) } == [["pixelbook", "codevisor"], ["none"], ["new"]])
    #expect(result.itemCount == 4)
    #expect(result.dividerCount == 2)
  }

  @Test("Unstarring restores the original choice order")
  func removedFavorites() {
    let result = results(favorites: [])
    #expect(result.sections.map(\.id) == ["projects", "actions"])
    #expect(result.items.map(\.id) == ["none", "codevisor", "pixelbook", "new"])
    #expect(result.groupLabelCount == 0)
    #expect(result.dividerCount == 1)
  }

  @Test("Unknown, duplicate, and ineligible saved IDs never hide or duplicate rows")
  func staleFavorites() {
    let result = results(favorites: ["missing", "new", "pixelbook", "pixelbook"])
    #expect(result.sections.first?.items.map(\.id) == ["pixelbook"])
    #expect(result.items.map(\.id) == ["pixelbook", "none", "codevisor", "new"])
    #expect(results(favorites: ["missing", "new"]).sections.map(\.id) == ["projects", "actions"])
  }

  @Test("No project can be favorited and still matches alongside the new-project command")
  func noProjectFavorite() {
    let result = results(favorites: ["none"], query: "project")
    #expect(result.sections.map(\.title) == [nil, nil])
    #expect(result.sections.map { $0.items.map(\.id) } == [["none"], ["new"]])
    #expect(result.itemCount == 2)
    #expect(result.dividerCount == 1)
  }

  @Test("Filtering favorite and ordinary rows uses one collection and hides empty sections")
  func searchFavorites() {
    let favorite = results(favorites: ["pixelbook"], query: "  PIXEL  ")
    #expect(favorite.sections.map(\.title) == [nil])
    #expect(favorite.items.map(\.id) == ["pixelbook"])
    #expect(favorite.dividerCount == 0)

    let regular = results(favorites: ["pixelbook"], query: "codevisor")
    #expect(regular.sections.map(\.id) == ["projects"])
    #expect(regular.groupLabelCount == 0)

    let action = results(favorites: ["pixelbook"], query: "new")
    #expect(action.sections.map(\.id) == ["actions"])
    #expect(action.items.map(\.id) == ["new"])
    #expect(action.dividerCount == 0)
    #expect(!action.isEmpty)

    let empty = results(favorites: ["pixelbook"], query: "missing")
    #expect(empty.isEmpty)
    #expect(empty.groupLabelCount == 0)
    #expect(empty.dividerCount == 0)
  }

  @Test("Lifting every item out of a group removes that group's heading")
  func wholeGroup() {
    let grouped = [Autocomplete.Section(id: "machines", title: "Machines", items: [Candidate(id: "mac", title: "Mac")])]
    let result = results(favorites: ["mac"], sections: grouped)
    #expect(result.sections.map(\.title) == [nil])
    #expect(result.itemCount == 1)
    #expect(result.groupLabelCount == 0)
    #expect(result.dividerCount == 0)
  }

  @Test("Only favorites present in the current machine's catalog are shown")
  func changingCatalogs() {
    let favorites = ["shared-repository", "local-folder"]
    let local = [
      Autocomplete.Section(
        id: "projects",
        items: [
          Candidate(id: "local-folder", title: "Local"), Candidate(id: "shared-repository", title: "Shared"),
        ])
    ]
    let remote = [Autocomplete.Section(id: "projects", items: [Candidate(id: "shared-repository", title: "Shared")])]
    #expect(results(favorites: favorites, sections: local).items.map(\.id) == favorites)
    #expect(results(favorites: favorites, sections: remote).items.map(\.id) == ["shared-repository"])
    #expect(results(favorites: favorites, sections: local).items.map(\.id) == favorites)
  }

  @Test("Search and Return use the first favorite in rendered order")
  @MainActor
  func keyboardOrder() {
    let catalog = [
      Autocomplete.Section(
        id: "machines",
        items: [
          Candidate(id: "first", title: "First Mac"), Candidate(id: "favorite", title: "Favorite Mac"),
        ])
    ]
    let targets = results(favorites: ["favorite"], query: "mac", sections: catalog).items.map(\.id)
    let highlight = Autocomplete.Highlight<String>()
    highlight.reconcile(with: targets, query: "mac")
    var accepted: String?
    highlight.handle(.accept, targets: targets, accept: { accepted = $0 }, dismiss: {})
    #expect(accepted == "favorite")
    highlight.move(by: 1, in: targets)
    #expect(highlight.highlighted == "first")
  }
}
