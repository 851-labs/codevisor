import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use accessible click routes")
struct ComputerUseAccessibleRouteTests {
  private let label = ComputerUseRouteNode(role: "AXStaticText", actions: [], selectable: false)
  private let cell = ComputerUseRouteNode(role: "AXCell", actions: [], selectable: false)
  private let row = ComputerUseRouteNode(
    role: "AXRow", actions: ["AXShowAlternateUI", "AXShowDefaultUI"], selectable: true)
  private let sidebar = ComputerUseRouteNode(role: "AXOutline", actions: ["AXShowMenu"], selectable: false)

  @Test("A sidebar label selects its row and right-clicks through the list's menu")
  func sidebarRow() {
    let chain = [label, cell, row, sidebar]
    #expect(computerUseClickRoute(chain: chain, button: "left", count: 1) == .select(node: 2))
    #expect(computerUseClickRoute(chain: chain, button: "right", count: 1) == .showMenu(node: 3, selecting: 2))
    var selectedRow = row
    selectedRow.selected = true
    #expect(
      computerUseClickRoute(chain: [label, cell, selectedRow, sidebar], button: "right", count: 1)
        == .showMenu(node: 3, selecting: nil))
  }

  @Test("An editable table cell selects its row instead of confirming the field")
  func editableCell() {
    let cellField = ComputerUseRouteNode(role: "AXTextField", actions: ["AXConfirm", "AXShowMenu"], selectable: false)
    let tableRow = ComputerUseRouteNode(role: "AXRow", actions: [], selectable: true)
    let table = ComputerUseRouteNode(role: "AXTable", actions: [], selectable: false)
    #expect(computerUseClickRoute(chain: [cellField, tableRow, table], button: "left", count: 1) == .select(node: 1))
    let window = ComputerUseRouteNode(role: "AXWindow", actions: ["AXRaise"], selectable: false)
    #expect(computerUseClickRoute(chain: [cellField, window], button: "left", count: 1) == .pointer)
  }

  @Test("A label presses its nearest pressable ancestor")
  func pressableAncestor() {
    let button = ComputerUseRouteNode(role: "AXButton", actions: ["AXPress", "AXShowMenu"], selectable: false)
    let toolbar = ComputerUseRouteNode(role: "AXToolbar", actions: ["AXShowMenu"], selectable: false)
    #expect(
      computerUseClickRoute(chain: [label, button, toolbar], button: "left", count: 2)
        == .perform(node: 1, action: "AXPress"))
    #expect(
      computerUseClickRoute(chain: [label, button, toolbar], button: "right", count: 1)
        == .showMenu(node: 1, selecting: nil))
  }

  @Test("Falls back to the pointer when no accessibility route matches the click")
  func pointerFallbacks() {
    #expect(computerUseClickRoute(chain: [label, cell, row, sidebar], button: "left", count: 2) == .pointer)
    #expect(computerUseClickRoute(chain: [label, cell, row, sidebar], button: "middle", count: 1) == .pointer)
    let pressableList = ComputerUseRouteNode(role: "AXList", actions: ["AXPress", "AXShowMenu"], selectable: false)
    #expect(computerUseClickRoute(chain: [label, pressableList], button: "left", count: 1) == .pointer)
    #expect(computerUseClickRoute(chain: [label, pressableList], button: "right", count: 1) == .pointer)
    let window = ComputerUseRouteNode(role: "AXWindow", actions: ["AXRaise", "AXShowMenu"], selectable: false)
    #expect(computerUseClickRoute(chain: [label, window], button: "right", count: 1) == .pointer)
  }
}
