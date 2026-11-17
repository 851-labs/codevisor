import Testing
@testable import CodevisorUI

struct SidebarStepTests {
  @Test("A selection outside the list enters it at the first item going forward and the last going back")
  func selectionOutsideTheListEntersAtAnEnd() {
    let items = ["a", "b", "c"]

    #expect(SidebarStep.target(in: items, from: nil, by: 1) == "a")
    #expect(SidebarStep.target(in: items, from: nil, by: -1) == "c")
    #expect(SidebarStep.target(in: [String](), from: nil, by: 1) == nil)
  }

  @Test("A listed selection moves by the offset and stops at the ends")
  func listedSelectionStopsAtTheEnds() {
    let items = ["a", "b", "c"]

    #expect(SidebarStep.target(in: items, from: 1, by: 1) == "c")
    #expect(SidebarStep.target(in: items, from: 1, by: -1) == "a")
    #expect(SidebarStep.target(in: items, from: 2, by: 1) == nil)
    #expect(SidebarStep.target(in: items, from: 0, by: -1) == nil)
  }

  private func step(_ rows: [String], from current: String?, by offset: Int) -> String? {
    SidebarStep.target(among: rows, isCurrent: { $0 == current }, by: offset) { row in
      row.hasPrefix("-") ? nil : row.uppercased()
    }
  }

  @Test("Stepping over rows skips the ones that are not stops and resolves only what it lands on")
  func steppingOverRowsSkipsNonStops() {
    let rows = ["-heading", "a", "-group", "b", "c"]

    #expect(step(rows, from: "a", by: 1) == "B")
    #expect(step(rows, from: "b", by: -1) == "A")
    #expect(step(rows, from: "c", by: 1) == nil)
    #expect(step(rows, from: "a", by: -1) == nil)
  }

  @Test("Stepping over rows enters at an end when the selection is not a stop in the list")
  func steppingOverRowsEntersAtAnEnd() {
    let rows = ["-heading", "a", "b", "-more"]

    #expect(step(rows, from: nil, by: 1) == "A")
    #expect(step(rows, from: nil, by: -1) == "B")
    #expect(step(rows, from: "-heading", by: 1) == "A")
    #expect(step([], from: nil, by: 1) == nil)
  }

  @Test("Stepping over rows matches stepping over the resolved stops")
  func steppingOverRowsMatchesSteppingOverStops() {
    let rows = ["a", "-x", "b", "-y", "c", "d"]
    let stops = rows.filter { !$0.hasPrefix("-") }

    for current in stops + ["missing"] {
      for offset in [-2, -1, 1, 2] {
        let expected = SidebarStep.target(in: stops, from: stops.firstIndex(of: current), by: offset)
        #expect(step(rows, from: current, by: offset) == expected?.uppercased())
      }
    }
  }
}
