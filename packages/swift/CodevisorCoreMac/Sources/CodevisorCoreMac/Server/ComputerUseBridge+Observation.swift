import ApplicationServices
import Foundation

func computerUseActionLabel(_ action: String) -> String {
  guard action.hasPrefix("Name:") else { return action }
  return String(action.dropFirst(5).split(separator: "\n").first ?? "")
}

func computerUseWindowButtonLabel(subrole: String?) -> String? {
  switch subrole {
  case "AXCloseButton": "Close window"
  case "AXMinimizeButton": "Minimize window"
  case "AXZoomButton": "Zoom window"
  case "AXFullScreenButton": "Full screen"
  default: nil
  }
}

func computerUseMenuShortcut(character: String?, modifiers: Int?) -> String? {
  guard let character, character.count == 1, let scalar = character.unicodeScalars.first,
    scalar.isASCII, scalar.value > 32, scalar.value < 127
  else { return nil }
  let flags = modifiers ?? 0
  let names =
    (flags & 8 == 0 ? ["super"] : [])
    + [(4, "ctrl"), (2, "alt"), (1, "shift")].filter { flags & $0.0 != 0 }.map(\.1)
  return (names + [character.lowercased()]).joined(separator: "+")
}

func computerUseIsLabelText(_ text: String) -> Bool {
  text.contains { $0.isLetter }
}

func computerUseHiddenAction(_ action: String) -> Bool {
  ["AXShowAlternateUI", "AXShowDefaultUI"].contains(action)
}

struct ComputerUseSubtreeText {
  var label: String?
  var fallback: String?

  init(_ text: String? = nil) {
    guard let text else { return }
    if computerUseIsLabelText(text) { label = text } else { fallback = text }
  }

  var best: String? { label ?? fallback }

  mutating func absorb(_ other: ComputerUseSubtreeText) {
    if label == nil { label = other.label }
    if fallback == nil { fallback = other.fallback }
  }
}

func computerUseObservationValue(role: String, subrole: String?, value: Any?) -> String {
  if (role + (subrole ?? "")).localizedCaseInsensitiveContains("secure") { return "<redacted>" }
  if let value = value as? String { return value }
  if let value = value as? NSNumber { return value.stringValue }
  return ""
}

extension ComputerUseBridge {
  func openMenu(application: AXUIElement, window: AXUIElement, searchWindow: Bool = true) -> AXUIElement? {
    var focused = elementAttribute(application, kAXFocusedUIElementAttribute)
    for _ in 0..<12 {
      guard let element = focused else { break }
      if stringAttribute(element, kAXRoleAttribute) == "AXMenu", menuIsOpen(element) { return element }
      focused = elementAttribute(element, kAXParentAttribute)
    }
    var remaining = 1_500
    for child in elementsAttribute(application, kAXChildrenAttribute) {
      if stringAttribute(child, kAXRoleAttribute) == "AXMenu", menuIsOpen(child) { return child }
    }
    if searchWindow, let menu = findOpenMenu(window, remaining: &remaining) { return menu }
    if let bar = elementAttribute(application, kAXMenuBarAttribute) {
      return findOpenMenu(bar, remaining: &remaining)
    }
    return nil
  }

  func openMenu(near element: AXUIElement, application: AXUIElement) -> AXUIElement? {
    var scope: AXUIElement? = element
    var remaining = 400
    for _ in 0..<4 {
      guard let root = scope else { break }
      if let menu = findOpenMenu(root, remaining: &remaining) { return menu }
      scope = elementAttribute(root, kAXParentAttribute)
    }
    return openMenu(application: application, window: element, searchWindow: false)
  }

  private func findOpenMenu(_ element: AXUIElement, remaining: inout Int, depth: Int = 0) -> AXUIElement? {
    guard remaining > 0, depth < 64 else { return nil }
    remaining -= 1
    if stringAttribute(element, kAXRoleAttribute) == "AXMenu" { return menuIsOpen(element) ? element : nil }
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
    application: AXUIElement, window: AXUIElement, view: String, searchWindowForMenus: Bool = true
  ) -> (elements: [AXUIElement], view: String) {
    if view == "auto" || view == "menu",
      let menu = openMenu(application: application, window: window, searchWindow: searchWindowForMenus)
    {
      return ([menu], "menu")
    }
    if view == "menu" { return ([], "menu") }
    if view == "menubar" {
      let bar = elementAttribute(application, kAXMenuBarAttribute)
      let items = bar.map { elementsAttribute($0, kAXChildrenAttribute) } ?? []
      return (items.filter { stringAttribute($0, kAXTitleAttribute) != "Apple" }, "menubar")
    }
    let sheets = sheetElements(of: window)
    if (view == "auto" || view == "dialog"), !sheets.isEmpty { return (sheets, "dialog") }
    if view == "dialog" { return ([], "dialog") }
    return ([window], "window")
  }

  func dialogButtons(of roots: [AXUIElement]) -> [(element: AXUIElement, label: String)] {
    roots.flatMap { root in
      [(kAXDefaultButtonAttribute, "Default button"), (kAXCancelButtonAttribute, "Cancel button")].compactMap {
        attribute, label in elementAttribute(root, attribute).map { (element: $0, label: label) }
      }
    }
  }

  @discardableResult
  func snapshotTree(
    _ element: AXUIElement, depth: Int, screenshotWindowFrame: CGRect?, screenshotPixelSize: CGSize?,
    correctFrame: (AXUIElement, CGRect) -> CGRect, includeClosedMenus: Bool = false,
    dialogButtons: [(element: AXUIElement, label: String)] = [],
    previous: [CFHashCode: [(key: String, value: ElementRecord)]], nextIndex: inout Int,
    limits: inout ComputerUseSnapshotLimits, records: inout [String: ElementRecord], lines: inout [String],
    redundant: inout [Int: String]
  ) -> ComputerUseSubtreeText {
    guard depth <= 64, limits.admit(recordCount: records.count) else { return ComputerUseSubtreeText() }
    let attributes = ComputerUseElementAttributes(element)
    let role = attributes.string(kAXRoleAttribute) ?? "element"
    if ["AXBusyIndicator", "AXProgressIndicator"].contains(role) { limits.sawBusyIndicator = true }
    if role == "AXMenu", !includeClosedMenus {
      guard menuIsOpen(element) else { return ComputerUseSubtreeText() }
      if limits.openMenu == nil { limits.openMenu = element }
    }
    let linkedTitle = attributes[kAXTitleUIElementAttribute].flatMap { linked -> String? in
      guard CFGetTypeID(linked) == AXUIElementGetTypeID() else { return nil }
      let label = linked as! AXUIElement
      return stringAttribute(label, kAXValueAttribute) ?? stringAttribute(label, kAXTitleAttribute)
    }
    let title =
      [
        attributes.string(kAXTitleAttribute), attributes.string(kAXDescriptionAttribute), linkedTitle,
        computerUseWindowButtonLabel(subrole: attributes.string(kAXSubroleAttribute)),
      ]
      .compactMap { $0 }.first { !$0.isEmpty } ?? ""
    let value = computerUseObservationValue(
      role: role, subrole: attributes.string(kAXSubroleAttribute),
      value: attributes[kAXValueAttribute] ?? selectionDescription(of: element, role: role))
    let children = attributes.children
    let advertised = Array(
      Set(actionNames(of: element).filter { !computerUseHiddenAction($0) }.map(computerUseActionLabel))
    ).sorted()
    let actions = advertised.filter { title.isEmpty || !title.hasPrefix($0) }
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
    let labelsFromChildren = role == "AXRow" && title.isEmpty && !children.isEmpty
    let ownText =
      ["AXStaticText", "AXTextField"].contains(role)
      ? [value, title].first { !$0.isEmpty && $0 != "<redacted>" } : nil
    let describe = { (title: String, id: String) -> String in
      var line = "\(String(repeating: "  ", count: min(depth, 12)))\(id) \(role)"
      if !title.isEmpty { line += " \(title)" }
      if !value.isEmpty && value != title {
        let formatted = role == "AXTextArea" ? self.formattedTextValue(element: element, plainText: value) : nil
        line += " Value: \(String((formatted ?? value).prefix(4_000)))"
      }
      if editor, value.isEmpty, let placeholder = attributes.string(kAXPlaceholderValueAttribute),
        !placeholder.isEmpty
      {
        line += " Placeholder: \(placeholder.prefix(200))"
      }
      if title.isEmpty, let help = attributes.string(kAXHelpAttribute), !help.isEmpty {
        line += " Help: \(help.prefix(200))"
      } else if title.isEmpty, value.isEmpty, let identifier = attributes.string(kAXIdentifierAttribute),
        !identifier.isEmpty
      {
        line += " ID: \(identifier.prefix(120))"
      }
      if attributes[kAXSelectedAttribute] as? Bool == true { line += " Selected" }
      if role == "AXRow", let disclosing = attributes[kAXDisclosingAttribute] as? Bool,
        self.isSettable(element, attribute: kAXDisclosingAttribute)
      {
        line += disclosing ? " Expanded" : " Collapsed"
      }
      if role == "AXButton", let button = dialogButtons.first(where: { CFEqual($0.element, element) }) {
        line += " \(button.label)"
      }
      if role == "AXMenuItem",
        let shortcut = computerUseMenuShortcut(
          character: attributes.string(kAXMenuItemCmdCharAttribute),
          modifiers: (attributes[kAXMenuItemCmdModifiersAttribute] as? NSNumber)?.intValue)
      {
        line += " Shortcut: \(shortcut)"
      }
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
      return line
    }
    var recorded: (id: String, line: Int)?
    if labelsFromChildren || (!emptyContainer && !emptyLeaf && !separator) {
      let identity = attributes.identity
      let existing = previous[CFHash(element)]?.first {
        CFEqual($0.value.element, element) && $0.value.identity == identity
      }?.key
      let id = existing ?? String(nextIndex)
      if existing == nil { nextIndex += 1 }
      guard records[id] == nil else { return ComputerUseSubtreeText() }
      records[id] = ElementRecord(element: element, frame: elementFrame, identity: identity)
      recorded = (id, lines.count)
      if ["AXCell", "AXStaticText", "AXImage"].contains(role), actions.isEmpty, settable.isEmpty,
        let text = [title, value].first(where: { !$0.isEmpty })
      {
        redundant[lines.count] = text
      }
      lines.append(labelsFromChildren ? "" : describe(title, id))
    }
    let (walked, hiddenRows) = listChildren(of: element, role: role, children: children, limit: limits.rowsPerList)
    var subtreeText = ComputerUseSubtreeText(ownText)
    for child in walked {
      subtreeText.absorb(
        snapshotTree(
          child, depth: depth + 1, screenshotWindowFrame: screenshotWindowFrame,
          screenshotPixelSize: screenshotPixelSize, correctFrame: correctFrame,
          includeClosedMenus: includeClosedMenus, dialogButtons: dialogButtons, previous: previous,
          nextIndex: &nextIndex, limits: &limits, records: &records, lines: &lines, redundant: &redundant))
    }
    if let hiddenRows { lines.append("\(String(repeating: "  ", count: min(depth + 1, 12)))\(hiddenRows)") }
    guard let recorded else { return subtreeText }
    let label = labelsFromChildren ? subtreeText.best ?? title : title
    if labelsFromChildren {
      if subtreeText.best == nil, emptyContainer {
        lines[recorded.line] = ""
        records.removeValue(forKey: recorded.id)
        return subtreeText
      }
      lines[recorded.line] = describe(label, recorded.id)
    }
    if !label.isEmpty {
      for index in (recorded.line + 1)..<lines.count where redundant[index] == label {
        lines[index] = ""
        redundant.removeValue(forKey: index)
      }
    }
    return subtreeText
  }

  private func listChildren(
    of element: AXUIElement, role: String, children: [AXUIElement], limit: Int
  ) -> (walked: [AXUIElement], hiddenRowsNote: String?) {
    guard ["AXTable", "AXOutline"].contains(role) else {
      return visibleChildren(of: element, children: children, limit: limit)
    }
    let rows = elementsAttribute(element, kAXRowsAttribute)
    guard rows.count > limit else { return (children, nil) }
    let indicesByHash = Dictionary(grouping: rows.indices) { CFHash(rows[$0]) }
    let rowIndex = { (candidate: AXUIElement) -> Int? in
      indicesByHash[CFHash(candidate)]?.first { CFEqual(rows[$0], candidate) }
    }
    let shown = computerUseShownRows(
      total: rows.count,
      visible: elementsAttribute(element, kAXVisibleRowsAttribute).compactMap(rowIndex),
      limit: limit)
    return (
      children.filter { rowIndex($0).map(shown.contains) ?? true },
      computerUseHiddenRowsNote(shown: shown, total: rows.count)
    )
  }

  private func visibleChildren(
    of element: AXUIElement, children: [AXUIElement], limit: Int
  ) -> (walked: [AXUIElement], hiddenRowsNote: String?) {
    guard children.count > limit else { return (children, nil) }
    let indicesByHash = Dictionary(grouping: children.indices) { CFHash(children[$0]) }
    let visible = elementsAttribute(element, kAXVisibleChildrenAttribute).compactMap { candidate in
      indicesByHash[CFHash(candidate)]?.first { CFEqual(children[$0], candidate) }
    }
    let shown = computerUseShownRows(total: children.count, visible: visible, limit: limit)
    return (
      Array(children[shown]),
      computerUseHiddenRowsNote(shown: shown, total: children.count, noun: "items")
    )
  }
}
