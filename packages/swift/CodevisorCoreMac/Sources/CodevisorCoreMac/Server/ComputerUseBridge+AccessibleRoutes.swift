import AppKit
import ApplicationServices
import Foundation

let computerUseCollectionRoles: Set<String> = ["AXOutline", "AXTable", "AXList", "AXGrid", "AXBrowser"]
let computerUseRouteBoundaryRoles: Set<String> = computerUseCollectionRoles.union([
  "AXApplication", "AXWindow", "AXSheet", "AXDrawer", "AXPopover", "AXScrollArea", "AXSplitGroup",
  "AXToolbar", "AXTabGroup", "AXWebArea", "AXMenu", "AXMenuBar",
])
let computerUsePressActions = [kAXPressAction as String, kAXConfirmAction as String, "AXPick", "AXOpen"]
let computerUseEditorRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
private let computerUseMaximumRouteAncestors = 4

struct ComputerUseRouteNode: Equatable {
  let role: String
  let actions: [String]
  let selectable: Bool
  var selected = false

  var isBoundary: Bool { computerUseRouteBoundaryRoles.contains(role) }
}

enum ComputerUseAccessibleRoute: Equatable {
  case perform(node: Int, action: String)
  case select(node: Int)
  case showMenu(node: Int, selecting: Int?)
  case pointer

  var selects: Bool {
    if case .select = self { return true }
    return false
  }
}

func computerUseClickRoute(chain: [ComputerUseRouteNode], button: String, count: Int) -> ComputerUseAccessibleRoute {
  switch button {
  case "left":
    for (index, node) in chain.enumerated() {
      guard index == 0 || !node.isBoundary, index <= computerUseMaximumRouteAncestors else { break }
      if !computerUseEditorRoles.contains(node.role),
        let action = computerUsePressActions.first(where: node.actions.contains)
      {
        return .perform(node: index, action: action)
      }
      if node.selectable {
        return count == 1 ? .select(node: index) : .pointer
      }
    }
  case "right":
    var item: Int?
    for (index, node) in chain.enumerated() {
      guard index <= computerUseMaximumRouteAncestors + 1 else { break }
      if index > 0, node.isBoundary, !computerUseCollectionRoles.contains(node.role) { break }
      if node.actions.contains(kAXShowMenuAction as String) {
        if !computerUseCollectionRoles.contains(node.role) || index == 0 {
          return .showMenu(node: index, selecting: nil)
        }
        guard let item else { break }
        return .showMenu(node: index, selecting: chain[item].selected ? nil : item)
      }
      if item == nil, node.selectable { item = index }
    }
  default: break
  }
  return .pointer
}

extension ComputerUseBridge {
  func routeChain(from element: AXUIElement) -> [(element: AXUIElement, node: ComputerUseRouteNode)] {
    var chain: [(element: AXUIElement, node: ComputerUseRouteNode)] = []
    var current: AXUIElement? = element
    while let candidate = current, chain.count <= computerUseMaximumRouteAncestors + 1 {
      let role = stringAttribute(candidate, kAXRoleAttribute) ?? ""
      let parent = elementAttribute(candidate, kAXParentAttribute)
      let node = ComputerUseRouteNode(
        role: role,
        actions: actionNames(of: candidate),
        selectable: selectionAttribute(for: candidate, role: role, parent: parent) != nil,
        selected: copyAttribute(candidate, kAXSelectedAttribute) as? Bool == true
      )
      chain.append((candidate, node))
      if node.isBoundary { break }
      current = parent
    }
    return chain
  }

  private func selectionAttribute(
    for element: AXUIElement, role: String, parent: AXUIElement?
  ) -> (owner: AXUIElement, attribute: String)? {
    if let parent, computerUseCollectionRoles.contains(stringAttribute(parent, kAXRoleAttribute) ?? "") {
      if role == "AXRow", isSettable(parent, attribute: kAXSelectedRowsAttribute) {
        return (parent, kAXSelectedRowsAttribute)
      }
      if isSettable(parent, attribute: kAXSelectedChildrenAttribute) {
        return (parent, kAXSelectedChildrenAttribute)
      }
    }
    if role == "AXRow", isSettable(element, attribute: kAXSelectedAttribute) {
      return (element, kAXSelectedAttribute)
    }
    return nil
  }

  func select(element: AXUIElement, pid: pid_t, extending: Bool = false) -> (error: AXError, verified: Bool) {
    let role = stringAttribute(element, kAXRoleAttribute) ?? ""
    let parent = elementAttribute(element, kAXParentAttribute)
    guard let selection = selectionAttribute(for: element, role: role, parent: parent) else {
      return (.attributeUnsupported, false)
    }
    let value: CFTypeRef
    if selection.attribute == kAXSelectedAttribute {
      value = kCFBooleanTrue
    } else {
      let current = extending ? elementsAttribute(selection.owner, selection.attribute) : []
      value = (current.contains { CFEqual($0, element) } ? current : current + [element]) as CFArray
    }
    let error = axSetAttribute(selection.owner, selection.attribute as CFString, value, pid: pid)
    let verified =
      copyAttribute(element, kAXSelectedAttribute) as? Bool == true
      || (selection.attribute != kAXSelectedAttribute
        && elementsAttribute(selection.owner, selection.attribute).contains { CFEqual($0, element) })
    if verified, let collection = selection.attribute == kAXSelectedAttribute ? parent : selection.owner,
      computerUseCollectionRoles.contains(stringAttribute(collection, kAXRoleAttribute) ?? ""),
      copyAttribute(collection, kAXFocusedAttribute) as? Bool != true,
      isSettable(collection, attribute: kAXFocusedAttribute)
    {
      _ = axSetAttribute(collection, kAXFocusedAttribute as CFString, kCFBooleanTrue, pid: pid)
    }
    return (error, verified)
  }

  func setExpanded(_ target: AXUIElement, expanded: Bool, pid: pid_t) throws -> [String: Any] {
    var current: AXUIElement? = target
    for _ in 0...computerUseMaximumRouteAncestors {
      guard let element = current else { break }
      let role = stringAttribute(element, kAXRoleAttribute) ?? ""
      if isSettable(element, attribute: kAXDisclosingAttribute) {
        let error = axSetAttribute(
          element, kAXDisclosingAttribute as CFString, expanded ? kCFBooleanTrue : kCFBooleanFalse, pid: pid)
        let verified = copyAttribute(element, kAXDisclosingAttribute) as? Bool == expanded
        var result = try accessibilityMutationResult(
          error: error, kind: "set_expanded", verified: verified, detail: ["expanded": expanded])
        if !CFEqual(element, target) { result["actedOn"] = role }
        return result
      }
      if role == "AXDisclosureTriangle", actionNames(of: element).contains(kAXPressAction as String) {
        let isExpanded = (copyAttribute(element, kAXValueAttribute) as? NSNumber)?.boolValue
        if isExpanded == expanded {
          return actionResultMetadata(
            kind: "set_expanded", path: "accessibility", verified: true, detail: ["expanded": expanded])
        }
        let error = axPerformAction(element, kAXPressAction as CFString, pid: pid)
        let verified = (copyAttribute(element, kAXValueAttribute) as? NSNumber)?.boolValue == expanded
        return try accessibilityMutationResult(
          error: error, kind: "set_expanded", verified: verified, detail: ["expanded": expanded])
      }
      if computerUseRouteBoundaryRoles.contains(role) { break }
      current = elementAttribute(element, kAXParentAttribute)
    }
    throw BridgeError("This element is not in an expandable row or disclosure triangle. Observe the app again.")
  }

  func accessibleClickResult(
    target: AXUIElement, button: String, count: Int, extendingSelection: Bool, app: NSRunningApplication,
    application: AXUIElement, window: AXUIElement, mode: String
  ) throws -> [String: Any]? {
    let chain = routeChain(from: target)
    let route = computerUseClickRoute(chain: chain.map(\.node), button: button, count: count)
    if extendingSelection, !route.selects {
      throw BridgeError("extend_selection applies to a single left click on a selectable list or table row.")
    }
    if button == "left", count == 1, !route.selects, computerUseEditorRoles.contains(chain[0].node.role) {
      try focus(element: target, application: application, pid: app.processIdentifier)
      return actionResultMetadata(
        kind: "click", path: "accessibility", deliveryMode: mode,
        verified: copyAttribute(target, kAXFocusedAttribute) as? Bool == true,
        detail: ["addressing": "element", "accessibilityAction": "focus"])
    }
    var result: [String: Any]
    switch route {
    case .pointer:
      return nil
    case .perform(let index, let action):
      if chain[index].node.role == "AXMenuItem",
        copyAttribute(chain[index].element, kAXEnabledAttribute) as? Bool == false
      {
        throw BridgeError(
          "That menu item is disabled, so pressing it would do nothing. A background app may not update menu bar items until its menus are opened; use the item's context menu or another accessibility route."
        )
      }
      result = [:]
      for _ in 0..<count {
        result = try accessibilityActionResult(
          element: chain[index].element, action: action, app: app,
          application: application, window: window, kind: "click")
        if result["status"] as? String == "uncertain" { break }
      }
      if index > 0 { result["actedOn"] = chain[index].node.role }
    case .select(let index):
      let outcome = select(
        element: chain[index].element, pid: app.processIdentifier, extending: extendingSelection)
      result = try accessibilityMutationResult(
        error: outcome.error, kind: "click", verified: outcome.verified,
        detail: ["accessibilityAction": "select"])
      if index > 0 { result["actedOn"] = chain[index].node.role }
    case .showMenu(let index, let selecting):
      if let selecting {
        let outcome = select(element: chain[selecting].element, pid: app.processIdentifier)
        guard outcome.verified else {
          throw BridgeError(
            "The item could not be selected before opening its container's menu (AXError \(outcome.error.rawValue)). Observe before retrying."
          )
        }
      }
      result = try accessibilityActionResult(
        element: chain[index].element, action: kAXShowMenuAction as String, app: app,
        application: application, window: window, kind: "click")
      if index > 0 { result["actedOn"] = chain[index].node.role }
      if selecting != nil { result["selectedFirst"] = true }
    }
    result["addressing"] = "element"
    result["deliveryMode"] = mode
    return result
  }

  func rowLabel(_ row: AXUIElement) -> String? {
    var queue: [(AXUIElement, Int)] = elementsAttribute(row, kAXChildrenAttribute).map { ($0, 1) }
    var visited = 0
    while !queue.isEmpty, visited < 12 {
      let (element, depth) = queue.removeFirst()
      visited += 1
      if ["AXStaticText", "AXTextField"].contains(stringAttribute(element, kAXRoleAttribute) ?? ""),
        let text = stringAttribute(element, kAXValueAttribute) ?? stringAttribute(element, kAXTitleAttribute),
        !text.isEmpty
      {
        return text
      }
      if depth < 3 { queue += elementsAttribute(element, kAXChildrenAttribute).map { ($0, depth + 1) } }
    }
    return nil
  }
}
