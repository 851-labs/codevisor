import AppKit
import ApplicationServices
import Foundation

func computerUseFindMatches(
  query: String?, role wanted: String?, role: String, subrole: String?, texts: [String]
)
  -> Bool
{
  if let wanted, !wanted.isEmpty, wanted != role, wanted != subrole { return false }
  guard let query, !query.isEmpty else { return true }
  return texts.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
}

private struct ComputerUseFindSearch {
  let query: String?
  let role: String?
  let limit: Int
  let previous: [CFHashCode: [(key: String, value: ComputerUseBridge.ElementRecord)]]
  let correctFrame: (AXUIElement, CGRect) -> CGRect
  var nextIndex: Int
  var limits: ComputerUseSnapshotLimits
  var records: [String: ComputerUseBridge.ElementRecord] = [:]
  var matches: [String] = []
  var items: [[String: Any]] = []
  var searched = 0
  var moreMatches = false

  var isFinished: Bool { moreMatches || matches.count >= limit }
}

extension ComputerUseBridge {
  static let findNodeBudget = 20_000

  func findElements(
    sessionID: String,
    agentLabel: String?,
    app name: String,
    requestedWindowID: CGWindowID?,
    options: [String: Any],
    budget: ComputerUseReadBudget
  ) throws -> [String: Any] {
    let query = (options["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let role = options["role"] as? String
    guard query?.isEmpty == false || role?.isEmpty == false else {
      throw BridgeError("find requires text or role")
    }
    let limit = int(options["limit"]) ?? 25
    guard (1...200).contains(limit) else { throw BridgeError("limit must be 1–200") }
    let requestedView = options["view"] as? String ?? "auto"
    guard ["auto", "window", "menu", "dialog", "menubar"].contains(requestedView) else {
      throw BridgeError("view must be auto, window, menu, dialog, or menubar")
    }
    try requireAccessibility(prompt: true)
    let app = try resolveApp(name)
    try ComputerUsePresentation.requireControlAllowed(
      sessionID: sessionID, pid: app.processIdentifier, resuming: true)
    let application = AXUIElementCreateApplication(app.processIdentifier)
    if let requestedWindowID {
      try selectSessionWindow(sessionID: sessionID, application: application, requestedWindowID: requestedWindowID)
    }
    let (window, windowID) = try sessionWindow(
      sessionID: sessionID, application: application, pid: app.processIdentifier)
    ComputerUseSyntheticActivation.shared.hold(app: app, sessionID: sessionID, windowID: windowID)
    settleAfterAction(sessionID: sessionID, pid: app.processIdentifier, budget: budget)
    activatePresentation(sessionID: sessionID, agentLabel: agentLabel, app: app, window: window, windowID: windowID)
    let scope = computerUseSnapshotScope(sessionID, app.processIdentifier, windowID)
    let (previous, startIndex) = lock.withLock {
      (latestSnapshotIDs[scope].flatMap { snapshots[sessionID]?[$0] }, nextElementIndices[sessionID] ?? 0)
    }
    let windowFrame = frame(of: window)
    let search = computerUsePerformAccessibilityRead(targetPID: app.processIdentifier) {
      let flipped =
        windowFrame.map {
          self.windowContentIsFlipped(application: application, window: window, windowID: windowID, windowFrame: $0)
        } ?? false
      var search = ComputerUseFindSearch(
        query: query, role: role, limit: limit,
        previous: Dictionary(grouping: previous?.elements ?? [:]) { CFHash($0.value.element) },
        correctFrame: { element, reported in
          guard flipped, let windowFrame else { return reported }
          return self.correctedFrame(
            of: element, reported: reported, application: application, windowFrame: windowFrame)
        },
        nextIndex: startIndex,
        limits: ComputerUseSnapshotLimits(
          budget: budget, nodes: Self.findNodeBudget, records: .max, rowsPerList: .max))
      let roots = self.observationRoots(
        application: application, window: window, view: requestedView,
        searchWindowForMenus: requestedView != "auto")
      for root in roots.elements {
        self.findWalk(root, ancestors: [], includeClosedMenus: roots.view == "menubar", search: &search)
      }
      return search
    }
    let snapshotID = UUID().uuidString
    storeSnapshot(
      sessionID: sessionID, scope: scope, snapshotID: snapshotID, nextIndex: search.nextIndex,
      record: SnapshotRecord(
        elements: (previous?.elements ?? [:]).merging(search.records) { $1 },
        pid: app.processIdentifier,
        windowID: windowID,
        windowFrame: previous?.windowFrame ?? windowFrame,
        screenshotPixelSize: previous?.screenshotPixelSize,
        createdAt: DispatchTime.now().uptimeNanoseconds,
        text: previous?.text ?? "",
        view: previous?.view ?? "find"
      ))
    var lines = Array(search.matches.prefix(limit))
    if lines.isEmpty { lines.append("No matching elements.") }
    if search.limits.stoppedForTime {
      lines.append(
        "Search stopped early to finish within the execute call's timeout after \(search.searched) elements; more matches may exist."
      )
    } else if search.limits.reachedSizeLimit {
      lines.append("Search stopped after \(search.searched) elements; more matches may exist.")
    }
    var metadata: [String: Any] = [
      "snapshotId": snapshotID,
      "app": name,
      "resolvedApp": [
        "id": app.bundleIdentifier ?? app.bundleURL?.path ?? name,
        "name": app.localizedName ?? name,
        "path": app.bundleURL?.path ?? "",
        "pid": app.processIdentifier,
        "isRunning": true,
      ],
      "text": lines.joined(separator: "\n"),
      "matchCount": min(search.matches.count, limit),
      "matches": Array(search.items.prefix(limit)),
      "searchedElements": search.searched,
    ]
    if let windowID { metadata["windowId"] = Int(windowID) }
    if search.moreMatches || search.matches.count > limit {
      metadata["next"] = "More elements match. Narrow text or role, or raise limit (maximum 200)."
    }
    return ["content": [["type": "text", "text": try json(metadata)]]]
  }

  @discardableResult
  private func findWalk(
    _ element: AXUIElement, ancestors: [String], includeClosedMenus: Bool, search: inout ComputerUseFindSearch
  ) -> ComputerUseSubtreeText {
    guard !search.isFinished, ancestors.count <= 64, search.limits.admit(recordCount: 0) else {
      return ComputerUseSubtreeText()
    }
    search.searched += 1
    let attributes = ComputerUseElementAttributes(element, names: ComputerUseElementAttributes.searchNames)
    let role = attributes.string(kAXRoleAttribute) ?? "element"
    let subrole = attributes.string(kAXSubroleAttribute)
    if role == "AXMenu", !includeClosedMenus, !menuIsOpen(element) { return ComputerUseSubtreeText() }
    let title =
      [attributes.string(kAXTitleAttribute), attributes.string(kAXDescriptionAttribute)]
      .compactMap { $0 }.first { !$0.isEmpty } ?? ""
    let value = computerUseObservationValue(role: role, subrole: subrole, value: attributes[kAXValueAttribute])
    let ownText =
      ["AXStaticText", "AXTextField"].contains(role)
      ? [value, title].first { !$0.isEmpty && $0 != "<redacted>" } : nil
    let texts = [
      title, value == "<redacted>" ? "" : value,
      attributes.string(kAXHelpAttribute) ?? "",
      attributes.string(kAXPlaceholderValueAttribute) ?? "",
      attributes.string(kAXIdentifierAttribute) ?? "",
    ]
    let labelsFromChildren = role == "AXRow" && title.isEmpty
    let position = search.matches.count
    let record = { (label: String, search: inout ComputerUseFindSearch) in
      let identity = attributes.identity
      let existing = search.previous[CFHash(element)]?.first {
        CFEqual($0.value.element, element) && $0.value.identity == identity
      }?.key
      let id = existing ?? String(search.nextIndex)
      if existing == nil { search.nextIndex += 1 }
      search.records[id] = ElementRecord(
        element: element, frame: frame(of: element).map { search.correctFrame(element, $0) }, identity: identity)
      var line = "\(id) \(role)"
      if !label.isEmpty { line += " \(label)" }
      if !value.isEmpty, value != label { line += " Value: \(value.prefix(200))" }
      if value.isEmpty, let placeholder = attributes.string(kAXPlaceholderValueAttribute), !placeholder.isEmpty {
        line += " Placeholder: \(placeholder.prefix(200))"
      }
      if attributes[kAXSelectedAttribute] as? Bool == true { line += " Selected" }
      if attributes[kAXEnabledAttribute] as? Bool == false { line += " Disabled" }
      if !ancestors.isEmpty { line += " — in \(ancestors.suffix(3).joined(separator: " › "))" }
      var item: [String: Any] = ["index": Int(id) ?? id, "role": role]
      if !label.isEmpty { item["label"] = label }
      if !value.isEmpty, value != label { item["value"] = String(value.prefix(200)) }
      if !ancestors.isEmpty { item["path"] = ancestors.suffix(3).joined(separator: " › ") }
      search.items.insert(item, at: min(position, search.items.count))
      search.matches.insert(line, at: min(position, search.matches.count))
      if search.matches.count > search.limit { search.moreMatches = true }
    }
    if !labelsFromChildren,
      computerUseFindMatches(query: search.query, role: search.role, role: role, subrole: subrole, texts: texts)
    {
      record(title, &search)
    }
    let path = title.isEmpty ? ancestors : ancestors + ["\(role) \(title.prefix(60))"]
    var subtreeText = ComputerUseSubtreeText(ownText)
    for child in attributes.children {
      subtreeText.absorb(findWalk(child, ancestors: path, includeClosedMenus: includeClosedMenus, search: &search))
    }
    let rowTexts = [subtreeText.label, subtreeText.fallback].compactMap { $0 }
    if labelsFromChildren,
      computerUseFindMatches(
        query: search.query, role: search.role, role: role, subrole: subrole, texts: rowTexts + texts)
    {
      record(subtreeText.best ?? "", &search)
    }
    return subtreeText
  }
}
