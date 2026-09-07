import Testing
@testable import CodevisorUI

struct BrowserToolbarScrollStateTests {
  @Test func readingDownCollapsesAndReadingUpExpands() {
    var state = BrowserToolbarScrollState()
    scroll(&state, to: 10)
    scroll(&state, to: 100)
    #expect(state.isCollapsed)
    scroll(&state, to: 500)
    scroll(&state, to: 489)
    #expect(state.isCollapsed)
    scroll(&state, to: 470)
    #expect(!state.isCollapsed)
  }

  @Test func smallDirectionChangesDoNotFlicker() {
    var state = BrowserToolbarScrollState()
    scroll(&state, to: 100)
    scroll(&state, to: 120)
    scroll(&state, to: 115)
    scroll(&state, to: 135)
    #expect(!state.isCollapsed)
    scroll(&state, to: 170)
    #expect(state.isCollapsed)
    scroll(&state, to: 167)
    scroll(&state, to: 171)
    #expect(state.isCollapsed)
  }

  @Test func programmaticScrollDoesNotCollapse() {
    var state = BrowserToolbarScrollState()
    state.update(offset: 400, maximumOffset: 1_000, isUserScrolling: false, keepExpanded: false)
    #expect(!state.isCollapsed)
    scroll(&state, to: 401)
    #expect(!state.isCollapsed)
  }

  @Test func bottomBounceDoesNotExpandButReturningToTopDoes() {
    var state = BrowserToolbarScrollState()
    scroll(&state, to: 100)
    scroll(&state, to: 1_000)
    scroll(&state, to: 1_100)
    scroll(&state, to: 1_000)
    #expect(state.isCollapsed)
    scroll(&state, to: -50)
    #expect(!state.isCollapsed)
  }

  @Test func editingAndShortPagesKeepControlsExpanded() {
    var state = BrowserToolbarScrollState()
    state.setCollapsed(true)
    state.update(offset: 500, maximumOffset: 1_000, isUserScrolling: true, keepExpanded: true)
    #expect(!state.isCollapsed)
    state.setCollapsed(true)
    state.update(offset: 30, maximumOffset: 40, isUserScrolling: true, keepExpanded: false)
    #expect(!state.isCollapsed)
  }

  @Test func tappingToExpandRequiresFreshDownwardTravel() {
    var state = BrowserToolbarScrollState()
    scroll(&state, to: 100)
    scroll(&state, to: 300)
    state.setCollapsed(false)
    scroll(&state, to: 301)
    #expect(!state.isCollapsed)
    scroll(&state, to: 350)
    #expect(state.isCollapsed)
  }

  private func scroll(_ state: inout BrowserToolbarScrollState, to offset: Double) {
    state.update(offset: offset, maximumOffset: 1_000, isUserScrolling: true, keepExpanded: false)
  }
}
