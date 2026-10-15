import AppKit
import ApplicationServices
import Foundation

extension ComputerUseBridge {
  func handleWindowedTool(
    tool: String, arguments: [String: Any], sessionID: String, agentLabel: String?,
    appName: String, app: NSRunningApplication, application: AXUIElement,
    window: AXUIElement, windowID: CGWindowID?
  ) throws -> [String: Any] {
    let mode = try deliveryMode(arguments)
    if tool == "paste_text", mode != "foreground" {
      throw BridgeError(
        "paste_text requires foreground delivery and foreground_reason. Prefer background type_text or set_value for plain text."
      )
    }
    return try performWithDelivery(app: app, window: window, windowID: windowID, mode: mode, sessionID: sessionID) {
      try self.performWindowedTool(
        tool: tool, arguments: arguments, sessionID: sessionID,
        agentLabel: agentLabel, app: app, application: application, window: window, windowID: windowID, mode: mode)
    }
  }

  private func performWindowedTool(
    tool: String, arguments: [String: Any], sessionID: String, agentLabel: String?,
    app: NSRunningApplication, application: AXUIElement, window: AXUIElement,
    windowID: CGWindowID?, mode: String
  ) throws -> [String: Any] {
    let wasHidden = copyAttribute(application, kAXHiddenAttribute) as? Bool == true
    let target = try targetElement(
      sessionID: sessionID, pid: app.processIdentifier, windowID: windowID, arguments: arguments)
    activatePresentation(sessionID: sessionID, agentLabel: agentLabel, app: app, window: window, windowID: windowID)
    if tool == "drag" {
      try requireInputVisibility(windowID: windowID, mode: mode)
    }
    var result: [String: Any]
    switch tool {
    case "click":
      result = try clickAction(
        arguments: arguments, target: target, sessionID: sessionID, app: app,
        application: application, window: window, windowID: windowID, mode: mode)
    case "perform_secondary_action":
      result = try secondaryAction(
        arguments: arguments, target: target, app: app, application: application, window: window)
    case "drag":
      let start = try dragPoint(
        prefix: "from", window: window, windowID: windowID, sessionID: sessionID, arguments: arguments)
      let end = try dragPoint(
        prefix: "to", window: window, windowID: windowID, sessionID: sessionID, arguments: arguments)
      ComputerUsePresentation.moveCursor(sessionID: sessionID, to: start)
      try drag(
        from: start, to: end, pid: app.processIdentifier, global: mode == "foreground", windowID: windowID,
        windowFrame: frame(of: window))
      ComputerUsePresentation.moveCursor(sessionID: sessionID, to: end, pulse: true)
      result = actionResultMetadata(
        kind: tool, path: mode == "foreground" ? "cgevent_global" : "cgevent_pid", deliveryMode: mode)
    case "press_key":
      let keys = (arguments["keys"] as? [String]) ?? (arguments["key"] as? String).map { [$0] } ?? []
      guard !keys.isEmpty, keys.count <= 32, arguments["keys"] == nil || arguments["key"] == nil else {
        throw BridgeError("Supply key or a sequence of 1–32 keys.")
      }
      for key in keys { try validateKey(key) }
      for key in keys { try keyPress(key, pid: app.processIdentifier, global: mode == "foreground") }
      result = actionResultMetadata(
        kind: tool, path: mode == "foreground" ? "cgevent_global" : "cgevent_pid", deliveryMode: mode)
    case "scroll":
      let direction = arguments["direction"] as? String ?? "down"
      let pages = double(arguments["pages"]) ?? 1
      guard pages.isFinite, pages > 0, ["up", "down", "left", "right", "u", "d", "l", "r"].contains(direction) else {
        throw BridgeError("Use a valid scroll direction and a positive number of pages.")
      }
      let action = [
        "up": "AXScrollUpByPage", "down": "AXScrollDownByPage", "left": "AXScrollLeftByPage",
        "right": "AXScrollRightByPage",
        "u": "AXScrollUpByPage", "d": "AXScrollDownByPage", "l": "AXScrollLeftByPage", "r": "AXScrollRightByPage",
      ][direction]!
      if let target, pages.rounded() == pages, pages <= 20, actionNames(of: target.element).contains(action) {
        result = [:]
        for _ in 0..<Int(pages) {
          result = try accessibilityActionResult(
            element: target.element, action: action, app: app, application: application, window: window, kind: tool)
          if result["status"] as? String == "uncertain" { break }
        }
      } else {
        try requireInputVisibility(windowID: windowID, mode: mode)
        let point: CGPoint
        if let target {
          point = try screenPoint(
            window: window, windowID: windowID, target: target, sessionID: sessionID, arguments: arguments)
        } else {
          guard let box = frame(of: window) else { throw BridgeError("The window has no scrollable frame") }
          point = CGPoint(x: box.midX, y: box.midY)
        }
        try scroll(
          at: point, direction: direction, pages: pages, pid: app.processIdentifier, global: mode == "foreground")
        result = actionResultMetadata(
          kind: tool, path: mode == "foreground" ? "cgevent_global" : "cgevent_pid", deliveryMode: mode)
      }
    case "set_value":
      guard let element = target?.element, let value = arguments["value"] else {
        throw BridgeError("A current element and value are required")
      }
      let coerced = try computerUseAccessibilityValue(value, matching: copyAttribute(element, kAXValueAttribute))
      let error = axSetAttribute(element, kAXValueAttribute as CFString, coerced, pid: app.processIdentifier)
      let verified = computerUseAccessibilityValuesMatch(copyAttribute(element, kAXValueAttribute), coerced)
      result = try accessibilityMutationResult(error: error, kind: tool, verified: verified)
      if arguments["submit"] as? Bool == true {
        if actionNames(of: element).contains(kAXConfirmAction as String) {
          let submitted = axPerformAction(element, kAXConfirmAction as CFString, pid: app.processIdentifier)
          result["submitted"] = computerUseAXOutcome(submitted).status != "rejected"
        } else {
          result["submitted"] = false
          result["next"] = "This element has no submit action. Press Return, or press the control that submits it."
        }
      }
    case "set_expanded":
      guard let element = target?.element, let expanded = arguments["expanded"] as? Bool else {
        throw BridgeError("A current element and expanded are required")
      }
      result = try setExpanded(element, expanded: expanded, pid: app.processIdentifier)
    case "window_action":
      guard let action = arguments["action"] as? String else { throw BridgeError("action is required") }
      result = try windowAction(action, window: window, application: application, pid: app.processIdentifier)
    case "type_text":
      if let element = target?.element {
        try focus(element: element, application: application, pid: app.processIdentifier)
      }
      guard let text = arguments["text"] as? String else { throw BridgeError("text is required") }
      try typeText(text, pid: app.processIdentifier, global: mode == "foreground")
      result = actionResultMetadata(
        kind: tool, path: mode == "foreground" ? "cgevent_global" : "cgevent_pid", deliveryMode: mode)
    case "paste_text":
      if let element = target?.element {
        try focus(element: element, application: application, pid: app.processIdentifier)
      }
      result = try pasteText(arguments: arguments, app: app, application: application)
    case "select_text":
      guard let element = target?.element else { throw BridgeError("A current element is required") }
      var range = try textSelectionRange(element: element, arguments: arguments)
      guard let value = AXValueCreate(.cfRange, &range) else { throw BridgeError("Invalid selection range") }
      let error = axSetAttribute(element, kAXSelectedTextRangeAttribute as CFString, value, pid: app.processIdentifier)
      let actual = selectedTextRange(element)
      result = try accessibilityMutationResult(
        error: error, kind: tool,
        verified: actual?.location == range.location && actual?.length == range.length,
        detail: ["start": range.location, "length": range.length])
    default: throw BridgeError("Unsupported Computer Use tool: \(tool)")
    }
    if let windowID { result["windowId"] = Int(windowID) }
    if wasHidden, copyAttribute(application, kAXHiddenAttribute) as? Bool == false {
      result["appBecameVisible"] = true
    }
    result["app"] = app.bundleIdentifier ?? app.localizedName ?? ""
    return textResult(try json(result))
  }
}

func computerUseAccessibilityValue(_ value: Any, matching current: CFTypeRef?) throws -> CFTypeRef {
  guard current is NSNumber, let text = value as? String else { return value as CFTypeRef }
  guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else {
    throw BridgeError("This element holds a number. Supply a numeric value.")
  }
  return NSNumber(value: number)
}

func computerUseAccessibilityValuesMatch(_ actual: CFTypeRef?, _ expected: CFTypeRef) -> Bool {
  if let actual = actual as? NSNumber, let expected = expected as? NSNumber {
    return abs(actual.doubleValue - expected.doubleValue) < 0.000_001
  }
  return actual.map { String(describing: $0) } == String(describing: expected)
}
