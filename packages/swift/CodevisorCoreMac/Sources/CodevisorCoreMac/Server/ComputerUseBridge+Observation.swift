import ApplicationServices
import Foundation

func computerUseObservationText(current: String, previous: String?) -> String {
  guard let previous else { return current }
  if current == previous { return "No changes." }
  let old = previous.components(separatedBy: "\n")
  let new = current.components(separatedBy: "\n")
  let oldSet = Set(old)
  let newSet = Set(new)
  return
    (old.filter { !newSet.contains($0) }.map { "- " + $0 }
    + new.filter { !oldSet.contains($0) }.map { "+ " + $0 }).joined(separator: "\n")
}

func computerUseActionLabel(_ action: String) -> String {
  guard action.hasPrefix("Name:") else { return action }
  return String(action.dropFirst(5).split(separator: "\n").first ?? "")
}

func computerUseObservationValue(role: String, subrole: String?, value: Any?) -> String {
  if (role + (subrole ?? "")).localizedCaseInsensitiveContains("secure") { return "<redacted>" }
  if let value = value as? String { return value }
  if let value = value as? NSNumber { return value.stringValue }
  return ""
}

extension ComputerUseBridge {
  /// Tracking menus can live outside AXWindow. Check the focused ancestor
  /// chain and menu bar as well as the window; ignore unopened submenu trees.
  func openMenu(application: AXUIElement, window: AXUIElement) -> AXUIElement? {
    var focused = elementAttribute(application, kAXFocusedUIElementAttribute)
    for _ in 0..<12 {
      guard let element = focused else { break }
      if stringAttribute(element, kAXRoleAttribute) == "AXMenu", menuIsOpen(element) { return element }
      focused = elementAttribute(element, kAXParentAttribute)
    }
    var remaining = 1_500
    // AppKit may publish a tracking menu beside its windows, rather than
    // beneath the originating control or the menu bar.
    for child in elementsAttribute(application, kAXChildrenAttribute) {
      if stringAttribute(child, kAXRoleAttribute) == "AXMenu", menuIsOpen(child) { return child }
    }
    if let menu = findOpenMenu(window, remaining: &remaining) { return menu }
    if let bar = elementAttribute(application, kAXMenuBarAttribute) {
      return findOpenMenu(bar, remaining: &remaining)
    }
    return nil
  }

  private func findOpenMenu(_ element: AXUIElement, remaining: inout Int, depth: Int = 0) -> AXUIElement? {
    guard remaining > 0, depth < 64 else { return nil }
    remaining -= 1
    if stringAttribute(element, kAXRoleAttribute) == "AXMenu", menuIsOpen(element) { return element }
    for child in elementsAttribute(element, kAXChildrenAttribute) {
      if let menu = findOpenMenu(child, remaining: &remaining, depth: depth + 1) { return menu }
    }
    return nil
  }

  func menuIsOpen(_ element: AXUIElement) -> Bool {
    elementsAttribute(element, kAXChildrenAttribute).contains {
      guard let box = frame(of: $0) else { return false }
      return box.width > 0 && box.height > 0 && abs(box.minX) < 100_000 && abs(box.minY) < 100_000
    }
  }

  func observationRoots(
    application: AXUIElement, window: AXUIElement, view: String
  ) -> (elements: [AXUIElement], view: String) {
    if view == "auto" || view == "menu", let menu = openMenu(application: application, window: window) {
      return ([menu], "menu")
    }
    if view == "menu" { return ([], "menu") }
    let sheets = sheetElements(of: window)
    if (view == "auto" || view == "dialog"), !sheets.isEmpty { return (sheets, "dialog") }
    if view == "dialog" { return ([], "dialog") }
    return ([window], "window")
  }

  func snapshotTree(
    _ element: AXUIElement, depth: Int, screenshotWindowFrame: CGRect?, screenshotPixelSize: CGSize?,
    correctFrame: (AXUIElement, CGRect) -> CGRect,
    previous: [CFHashCode: [(key: String, value: ElementRecord)]], nextIndex: inout Int, remaining: inout Int,
    records: inout [String: ElementRecord], lines: inout [String]
  ) {
    guard depth <= 64, records.count < 1_200, remaining > 0 else { return }
    remaining -= 1
    let attributes = ComputerUseElementAttributes(element)
    let role = attributes.string(kAXRoleAttribute) ?? "element"
    if role == "AXMenu", !menuIsOpen(element) { return }
    let title =
      [attributes.string(kAXTitleAttribute), attributes.string(kAXDescriptionAttribute)]
      .compactMap { $0 }.first { !$0.isEmpty } ?? ""
    let value = computerUseObservationValue(
      role: role, subrole: attributes.string(kAXSubroleAttribute),
      value: attributes[kAXValueAttribute] ?? selectionDescription(of: element, role: role))
    let children = attributes.children
    let actions = Array(Set(actionNames(of: element).map(computerUseActionLabel))).sorted()
    let editor = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
    let settable = [kAXValueAttribute, kAXSelectedTextRangeAttribute].filter {
      (attributes[$0] != nil || editor) && isSettable(element, attribute: $0)
    }
    let elementFrame = attributes.frame.map { correctFrame(element, $0) }
    let emptyContainer =
      ["AXGroup", "AXCell", "AXRow", "AXSplitGroup"].contains(role)
      && title.isEmpty && value.isEmpty && settable.isEmpty && actions.isEmpty
    let emptyLeaf = children.isEmpty && title.isEmpty && value.isEmpty && actions.isEmpty && settable.isEmpty
    let separator = role == "AXMenuItem" && title.isEmpty && value.isEmpty && children.isEmpty
    let include = !emptyContainer && !emptyLeaf && !separator
    if include {
      let identity = attributes.identity
      let existing = previous[CFHash(element)]?.first {
        CFEqual($0.value.element, element) && $0.value.identity == identity
      }?.key
      let id = existing ?? String(nextIndex)
      if existing == nil { nextIndex += 1 }
      guard records[id] == nil else { return }
      records[id] = ElementRecord(element: element, frame: elementFrame, identity: identity)
      var line = "\(String(repeating: "  ", count: min(depth, 12)))\(id) \(role)"
      if !title.isEmpty { line += " \(title)" }
      if !value.isEmpty && value != title {
        let formatted = role == "AXTextArea" ? formattedTextValue(element: element, plainText: value) : nil
        line += " Value: \(String((formatted ?? value).prefix(4_000)))"
      }
      if attributes[kAXSelectedAttribute] as? Bool == true { line += " Selected" }
      if attributes[kAXEnabledAttribute] as? Bool == false { line += " Disabled" }
      if let elementFrame, elementFrame.width > 0, elementFrame.height > 0,
        let box = computerUseScreenshotFrame(
          screenFrame: elementFrame, screenshotPixelSize: screenshotPixelSize, windowFrame: screenshotWindowFrame)
      {
        line +=
          " Frame: [\(box.minX.rounded()), \(box.minY.rounded()), \(box.width.rounded()), \(box.height.rounded())]"
      }
      if !actions.isEmpty { line += " Actions: \(actions.joined(separator: ", "))" }
      if !settable.isEmpty { line += " Settable: \(settable.joined(separator: ", "))" }
      if let selection = attributes.selection, selection.length > 0 {
        line += " Selection: \(selection.location):\(selection.length)"
      }
      lines.append(line)
    }
    for child in children {
      snapshotTree(
        child, depth: depth + 1, screenshotWindowFrame: screenshotWindowFrame,
        screenshotPixelSize: screenshotPixelSize, correctFrame: correctFrame, previous: previous,
        nextIndex: &nextIndex, remaining: &remaining, records: &records, lines: &lines)
    }
  }
}
