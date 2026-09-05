import AppKit
import ApplicationServices
import Foundation

func computerUseAXOutcome(_ error: AXError, menuOpened: Bool = false) -> (status: String, verified: Bool) {
  if menuOpened { return ("delivered", true) }
  if error == .success { return ("delivered", false) }
  if [.actionUnsupported, .illegalArgument, .invalidUIElement, .apiDisabled, .notImplemented].contains(error) {
    return ("rejected", false)
  }
  return ("uncertain", false)
}

extension ComputerUseBridge {
  func accessibilityMutationResult(
    error: AXError, kind: String, verified: Bool, detail: [String: Any] = [:]
  ) throws -> [String: Any] {
    let outcome = computerUseAXOutcome(error, menuOpened: verified)
    if outcome.status == "rejected" {
      throw BridgeError("\(kind) rejected (AXError \(error.rawValue)). Observe before retrying.")
    }
    var result = actionResultMetadata(kind: kind, path: "accessibility", verified: verified, detail: detail)
    result["status"] = outcome.status
    if error != .success { result["nativeErrorCode"] = error.rawValue }
    if outcome.status == "uncertain" {
      result["delivered"] = NSNull()
      result["next"] = "The action may have taken effect. Observe before deciding whether to retry."
    }
    return result
  }

  func requireInputVisibility(windowID: CGWindowID?, mode: String) throws {
    if mode == "background", let windowID, !windowIsOnVisibleSpace(windowID) {
      throw BridgeError(
        "Background input cannot reach this Space. Observe and explicitly choose delivery_mode foreground.")
    }
  }

  func accessibilityActionResult(
    element: AXUIElement, action: String, app: NSRunningApplication,
    application: AXUIElement, window: AXUIElement, kind: String
  ) throws -> [String: Any] {
    let error = axPerformAction(element, action as CFString, pid: app.processIdentifier)
    let menuOpened =
      action == kAXShowMenuAction as String
      && openMenu(application: application, window: window) != nil
    let outcome = computerUseAXOutcome(error, menuOpened: menuOpened)
    if outcome.status == "rejected" {
      throw BridgeError(
        "\(computerUseActionLabel(action)) rejected (AXError \(error.rawValue)). Observe the app before retrying.")
    }
    var result = actionResultMetadata(
      kind: kind, path: "accessibility", verified: outcome.verified,
      detail: ["accessibilityAction": computerUseActionLabel(action), "status": outcome.status])
    if error != .success { result["nativeErrorCode"] = error.rawValue }
    if menuOpened { result["effect"] = "menu_opened" }
    if outcome.status == "uncertain" {
      result["delivered"] = NSNull()
      result["next"] =
        "The action may have taken effect. Observe the app before deciding whether to retry; do not repeat it blindly."
    }
    return result
  }

  func clickAction(
    arguments: [String: Any], target: ElementRecord?, sessionID: String,
    app: NSRunningApplication, application: AXUIElement, window: AXUIElement,
    windowID: CGWindowID?, mode: String
  ) throws -> [String: Any] {
    let count = int(arguments["clickCount"] ?? arguments["click_count"]) ?? 1
    guard (1...2).contains(count) else { throw BridgeError("click_count must be 1 or 2") }
    guard
      let button = computerUseMouseButton(
        named: (arguments["button"] ?? arguments["mouse_button"]) as? String ?? "left")
    else {
      throw BridgeError("mouse_button must be left, right, or middle")
    }
    guard target == nil || (arguments["x"] == nil && arguments["y"] == nil) else {
      throw BridgeError("Choose an element or screenshot coordinates, not both.")
    }
    if let target {
      if button == "left", count == 1,
        ["AXTextField", "AXTextArea", "AXComboBox"].contains(stringAttribute(target.element, kAXRoleAttribute) ?? "")
      {
        try focus(element: target.element, application: application, pid: app.processIdentifier)
        return actionResultMetadata(
          kind: "click", path: "accessibility", deliveryMode: mode,
          verified: copyAttribute(target.element, kAXFocusedAttribute) as? Bool == true,
          detail: ["addressing": "element", "accessibilityAction": "focus"])
      }
      let desired =
        button == "right"
        ? [kAXShowMenuAction as String]
        : button == "left" ? [kAXPressAction as String, kAXConfirmAction as String, "AXPick", "AXOpen"] : []
      let advertised = actionNames(of: target.element)
      if let action = desired.first(where: { advertised.contains($0) }) {
        var result: [String: Any] = [:]
        for _ in 0..<count {
          result = try accessibilityActionResult(
            element: target.element, action: action, app: app,
            application: application, window: window, kind: "click")
          if result["status"] as? String == "uncertain" { break }
        }
        result["addressing"] = "element"
        result["deliveryMode"] = mode
        return result
      }
    }
    try requireInputVisibility(windowID: windowID, mode: mode)
    let point = try screenPoint(
      window: window, windowID: windowID, target: target, sessionID: sessionID, arguments: arguments)
    let delivery = deliveryTarget(point: point, window: window, windowID: windowID, windowFrame: frame(of: window))
    ComputerUsePresentation.moveCursor(sessionID: sessionID, to: point)
    let path = try mouseClick(
      point, count: count, button: button, pid: app.processIdentifier,
      windowID: delivery.windowID, windowFrame: delivery.windowFrame,
      chromium: computerUseUsesChromiumInput(
        appName: app.localizedName, bundleIdentifier: app.bundleIdentifier, executablePath: app.executableURL?.path),
      global: mode == "foreground")
    ComputerUsePresentation.moveCursor(sessionID: sessionID, to: point, pulse: true)
    return actionResultMetadata(
      kind: "click", path: path, deliveryMode: mode,
      detail: ["addressing": target == nil ? "pixel" : "element"])
  }

  func secondaryAction(
    arguments: [String: Any], target: ElementRecord?, app: NSRunningApplication,
    application: AXUIElement, window: AXUIElement
  ) throws -> [String: Any] {
    guard let target, let requested = arguments["action"] as? String else {
      throw BridgeError("A current element and action are required")
    }
    let actions = actionNames(of: target.element).filter {
      $0 == requested || computerUseActionLabel($0) == requested
    }
    guard actions.count == 1, let action = actions.first else {
      throw BridgeError("That action is unavailable or ambiguous. Use an action from the current observation.")
    }
    return try accessibilityActionResult(
      element: target.element, action: action, app: app,
      application: application, window: window, kind: "perform_secondary_action")
  }
}
