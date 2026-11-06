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
}
