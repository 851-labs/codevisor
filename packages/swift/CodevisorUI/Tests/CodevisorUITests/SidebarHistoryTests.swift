import Testing
@testable import CodevisorUI

struct SidebarHistoryTests {
  private struct Page: Identifiable, Hashable {
    let id: String
    var tab = "main"
  }

  private func history(_ ids: String..., limit: Int = SidebarHistory<Page>.defaultLimit) -> SidebarHistory<Page> {
    var history = SidebarHistory<Page>(limit: limit)
    for id in ids { history.visit(Page(id: id)) }
    return history
  }

  private func everything(_: Page) -> Bool { true }

  @Test func goesBackAndForwardThroughVisitedPages() {
    var history = history("bot", "chat", "workspace")

    #expect(history.goBack(where: everything)?.id == "chat")
    #expect(history.goBack(where: everything)?.id == "bot")
    #expect(history.goBack(where: everything) == nil)
    #expect(history.goForward(where: everything)?.id == "chat")
    #expect(history.goForward(where: everything)?.id == "workspace")
    #expect(history.goForward(where: everything) == nil)
  }

  @Test func reportsWhetherThereIsSomewhereToGo() {
    var history = history("bot", "chat")

    #expect(history.canGoBack(where: everything))
    #expect(!history.canGoForward(where: everything))
    _ = history.goBack(where: everything)
    #expect(!history.canGoBack(where: everything))
    #expect(history.canGoForward(where: everything))
  }

  @Test func visitingAfterGoingBackDropsTheForwardPages() {
    var history = history("a", "b", "c")
    _ = history.goBack(where: everything)
    _ = history.goBack(where: everything)

    history.visit(Page(id: "d"))

    #expect(!history.canGoForward(where: everything))
    #expect(history.goBack(where: everything)?.id == "a")
  }

  @Test func revisitingTheCurrentPageUpdatesItWithoutAddingAnEntry() {
    var history = history("a", "b")

    history.visit(Page(id: "b", tab: "terminal"))

    #expect(history.goBack(where: everything)?.id == "a")
    #expect(history.goForward(where: everything) == Page(id: "b", tab: "terminal"))
  }

  @Test func revisitingThePageWentBackToKeepsTheForwardPages() {
    var history = history("a", "b")
    _ = history.goBack(where: everything)

    history.visit(Page(id: "a", tab: "second chat"))

    #expect(history.goForward(where: everything)?.id == "b")
    #expect(history.goBack(where: everything) == Page(id: "a", tab: "second chat"))
  }

  @Test func skipsPagesThatAreNoLongerAvailableWithoutForgettingThem() {
    var history = history("a", "archived", "b")
    var gone: Set<String> = ["archived"]

    #expect(history.goBack(where: { !gone.contains($0.id) })?.id == "a")
    #expect(history.goForward(where: { !gone.contains($0.id) })?.id == "b")
    gone = []
    #expect(history.goBack(where: { !gone.contains($0.id) })?.id == "archived")
  }

  @Test func cannotMoveWhenOnlyUnavailablePagesRemain() {
    let history = history("deleted", "current")

    #expect(!history.canGoBack(where: { $0.id != "deleted" }))
  }

  @Test func leavingForAPageOutsideTheHistoryMakesBackReturnToTheLastPage() {
    var history = history("a", "b")

    history.leave()

    #expect(!history.canGoForward(where: everything))
    #expect(history.goBack(where: everything)?.id == "b")
    #expect(history.goBack(where: everything)?.id == "a")
  }

  @Test func leavingAfterGoingBackDropsTheForwardPages() {
    var history = history("a", "b")
    _ = history.goBack(where: everything)

    history.leave()

    #expect(history.goBack(where: everything)?.id == "a")
    #expect(!history.canGoForward(where: everything))
  }

  @Test func forgetsTheOldestPagesPastTheLimit() {
    var history = history("a", "b", "c", limit: 2)

    #expect(history.goBack(where: everything)?.id == "b")
    #expect(history.goBack(where: everything) == nil)
  }

  @Test func anEmptyHistoryHasNowhereToGo() {
    var history = SidebarHistory<Page>()
    history.leave()

    #expect(history.goBack(where: everything) == nil)
    #expect(history.goForward(where: everything) == nil)
  }
}
