import Testing
@testable import CodevisorUI

struct SidebarArchiveSelectionTests {
  private func next(
    archiving archived: String, selected: String? = nil, in sections: [[String]], leaving: Set<String> = []
  ) -> SidebarArchiveSelection<String> {
    SidebarArchiveSelection.after(
      archiving: archived, selected: selected ?? archived, sections: sections, leaving: leaving.union([archived]))
  }

  @Test func selectsTheRowThatSlidesUpIntoItsPlace() {
    #expect(next(archiving: "b", in: [["p"], ["a", "b", "c"], ["z"]]) == .select("c"))
  }

  @Test func theLastRowInASectionSelectsTheRowAbove() {
    #expect(next(archiving: "c", in: [["p"], ["a", "b", "c"], ["z"]]) == .select("b"))
  }

  @Test func anEmptiedSectionFallsToTheNearestRowBelowThenAbove() {
    #expect(next(archiving: "b", in: [["p", "q"], ["b"], [], ["y", "z"]]) == .select("y"))
    #expect(next(archiving: "b", in: [["p", "q"], [], ["b"]]) == .select("q"))
  }

  @Test func archivingTheLastWorkspaceClearsTheSelection() {
    #expect(next(archiving: "a", in: [[], ["a"]]) == .clear)
  }

  @Test func archivingAnUnselectedWorkspaceKeepsTheSelection() {
    #expect(next(archiving: "b", selected: "a", in: [["a", "b", "c"]]) == .unchanged)
    #expect(SidebarArchiveSelection.after(archiving: "b", selected: nil, sections: [["a", "b"]]) == .unchanged)
  }

  @Test func neverSelectsARowThatIsStillFoldingOut() {
    #expect(next(archiving: "b", in: [["x", "a", "b"]], leaving: ["a"]) == .select("x"))
    #expect(next(archiving: "b", in: [["a", "b"], ["c"]], leaving: ["a", "c"]) == .clear)
  }
}
