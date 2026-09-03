import Testing
@testable import Autocomplete

@Suite("Autocomplete highlight")
@MainActor
struct HighlightTests {
  private let targets = ["a", "b", "c"]

  @Test("Menus start unhighlighted and the first key picks an end")
  func menuStartsEmpty() {
    let highlight = Autocomplete.Highlight<String>(navigation: .menu)
    highlight.reconcile(with: targets)
    #expect(highlight.highlighted == nil)

    highlight.move(by: 1, in: targets)
    #expect(highlight.highlighted == "a")

    let fromBottom = Autocomplete.Highlight<String>(navigation: .menu)
    fromBottom.move(by: -1, in: targets)
    #expect(fromBottom.highlighted == "c")
  }

  @Test("Menus clamp at both ends")
  func menuClamps() {
    let highlight = Autocomplete.Highlight<String>(navigation: .menu)
    highlight.move(by: 1, in: targets)
    highlight.move(by: -1, in: targets)
    highlight.move(by: -1, in: targets)
    #expect(highlight.highlighted == "a")

    highlight.moveToLast(in: targets)
    highlight.move(by: 1, in: targets)
    #expect(highlight.highlighted == "c")
  }

  @Test("Inline popups auto-highlight the first item and loop")
  func inlineLoops() {
    let highlight = Autocomplete.Highlight<String>(navigation: .inline)
    highlight.reconcile(with: targets)
    #expect(highlight.highlighted == "a")

    highlight.move(by: -1, in: targets)
    #expect(highlight.highlighted == "c")
    highlight.move(by: 1, in: targets)
    #expect(highlight.highlighted == "a")
  }

  @Test("Filtering away the highlight drops it, or re-seeds with autoHighlight")
  func reconcileAfterFilter() {
    let menu = Autocomplete.Highlight<String>(navigation: .menu)
    menu.move(by: 1, in: targets)
    menu.move(by: 1, in: targets)
    #expect(menu.highlighted == "b")
    menu.reconcile(with: ["a", "c"])
    #expect(menu.highlighted == nil)

    let inline = Autocomplete.Highlight<String>(navigation: .inline)
    inline.reconcile(with: targets)
    inline.move(by: 1, in: targets)
    inline.reconcile(with: ["a", "c"])
    #expect(inline.highlighted == "a")

    inline.reconcile(with: [])
    #expect(inline.highlighted == nil)
  }

  @Test("Hover and keyboard drive one highlight; arrows move from the hovered item")
  func singleSourceOfTruth() {
    let highlight = Autocomplete.Highlight<String>(navigation: .menu)
    highlight.move(by: 1, in: targets)
    #expect(highlight.highlighted == "a")

    highlight.hover("c")
    #expect(highlight.highlighted == "c")
    #expect(highlight.source == .pointer)

    highlight.move(by: -1, in: targets)
    #expect(highlight.highlighted == "b", "the arrow moves from the hovered item, not a remembered keyboard one")
    #expect(highlight.source == .keyboard)
  }

  @Test("Leaving an item clears a menu highlight but never an auto-highlight")
  func leavingAnItem() {
    let menu = Autocomplete.Highlight<String>(navigation: .menu)
    menu.hover("b")
    menu.endHover("a")
    #expect(menu.highlighted == "b", "leaving a different item is a no-op")
    menu.endHover("b")
    #expect(menu.highlighted == nil)
    menu.move(by: 1, in: targets)
    #expect(menu.highlighted == "a", "with nothing highlighted the keyboard starts from the top")

    let inline = Autocomplete.Highlight<String>(navigation: .inline)
    inline.reconcile(with: targets)
    inline.hover("c")
    inline.endHover("c")
    #expect(inline.highlighted == "c", "auto-highlight keeps the last highlight rather than snapping")
  }

  @Test("Accept fires only for a visible highlight")
  func acceptRouting() {
    let highlight = Autocomplete.Highlight<String>(navigation: .menu)
    var accepted: String?
    var dismissed = false

    let handledWithoutTarget = highlight.handle(
      .accept, targets: targets, accept: { accepted = $0 }, dismiss: { dismissed = true })
    #expect(!handledWithoutTarget)
    #expect(accepted == nil)

    highlight.hover("a")
    highlight.handle(.accept, targets: ["b", "c"], accept: { accepted = $0 }, dismiss: {})
    #expect(accepted == nil, "a target hidden by filtering is not accepted")

    highlight.handle(.accept, targets: targets, accept: { accepted = $0 }, dismiss: {})
    #expect(accepted == "a", "Return accepts a hovered item just like a keyboard one")

    highlight.handle(.dismiss, targets: targets, accept: { _ in }, dismiss: { dismissed = true })
    #expect(dismissed)
  }
}
