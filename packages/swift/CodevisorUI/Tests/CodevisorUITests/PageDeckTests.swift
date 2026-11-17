import Testing
@testable import CodevisorUI

@MainActor
struct PageDeckTests {
  @Test("Showing a page activates it and deactivates the previous one in the same call")
  func showingSwitchesActivityAtOnce() {
    let deck = PageDeck<String, Int>(capacity: 3)
    deck.show(1, in: "a")
    let first = deck.activity(for: "a")

    let built = deck.show(2, in: "b")

    #expect(built)
    #expect(deck.activeSlot == "b")
    #expect(!first.isActive)
    #expect(deck.activity(for: "b").isActive)
    #expect(deck.pages.map(\.id) == ["a", "b"])
  }

  @Test("Returning to a mounted page reuses it and its activity")
  func returningReusesMountedPage() {
    let deck = PageDeck<String, Int>(capacity: 3)
    deck.show(1, in: "a")
    let first = deck.activity(for: "a")
    deck.show(2, in: "b")

    let built = deck.show(1, in: "a")

    #expect(!built)
    #expect(deck.activity(for: "a") === first)
    #expect(first.isActive)
  }

  @Test("Showing nothing keeps the pages mounted with none active")
  func showingNothingDeactivatesEveryPage() {
    let deck = PageDeck<String, Int>(capacity: 3)
    deck.show(1, in: "a")
    let activity = deck.activity(for: "a")

    deck.showNothing()

    #expect(deck.activeSlot == nil)
    #expect(!activity.isActive)
    #expect(deck.pages.map(\.id) == ["a"])
  }

  @Test("A page pushed out by newer ones is built again with a fresh activity")
  func evictedPageIsRebuilt() {
    let deck = PageDeck<String, Int>(capacity: 2)
    deck.show(1, in: "a")
    let evicted = deck.activity(for: "a")
    deck.show(2, in: "b")
    deck.show(3, in: "c")

    let built = deck.show(1, in: "a")

    #expect(built)
    #expect(deck.activity(for: "a") !== evicted)
    #expect(deck.pages.map(\.id) == ["c", "a"])
  }
}
