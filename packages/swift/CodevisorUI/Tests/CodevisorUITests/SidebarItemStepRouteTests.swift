import Testing
@testable import CodevisorUI

@MainActor
struct SidebarItemStepRouteTests {
  @MainActor
  private final class Steps {
    var page: [Int] = []
    var sidebar: [Int] = []
    var isPageShown = true

    func shownPage() -> SidebarItemStepRoute.Step? {
      guard isPageShown else { return nil }

      return { self.page.append($0) }
    }
  }

  @Test("A shown workspace page takes the step, so it can cycle its own tabs while the sidebar is hidden")
  func shownPageTakesTheStep() {
    let steps = Steps()
    let route = SidebarItemStepRoute(page: steps.shownPage, sidebar: { steps.sidebar.append($0) })

    route.step(1)
    route.step(-1)

    #expect(steps.page == [1, -1])
    #expect(steps.sidebar.isEmpty)
  }

  @Test("Page actions the menu still holds after an archived workspace replaced the page leave the step to the sidebar")
  func gonePageLeavesTheStepToTheSidebar() {
    let steps = Steps()
    let route = SidebarItemStepRoute(page: steps.shownPage, sidebar: { steps.sidebar.append($0) })

    route.step(1)
    steps.isPageShown = false
    route.step(1)
    route.step(-1)

    #expect(steps.page == [1])
    #expect(steps.sidebar == [1, -1])
  }
}
