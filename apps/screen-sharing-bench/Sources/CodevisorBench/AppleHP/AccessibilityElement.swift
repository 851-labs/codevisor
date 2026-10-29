import ApplicationServices

struct AccessibilityElement: @unchecked Sendable {
  let element: AXUIElement

  static func application(_ pid: pid_t) -> AccessibilityElement {
    AccessibilityElement(element: AXUIElementCreateApplication(pid))
  }

  func string(_ attribute: String) -> String? {
    value(attribute) as? String
  }

  func bool(_ attribute: String) -> Bool? {
    (value(attribute) as? NSNumber)?.boolValue
  }

  func children(_ attribute: String = kAXChildrenAttribute) -> [AccessibilityElement] {
    (value(attribute) as? [AXUIElement] ?? []).map(AccessibilityElement.init)
  }

  func element(_ attribute: String) -> AccessibilityElement? {
    guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }

    return AccessibilityElement(element: value as! AXUIElement)
  }

  var frame: CGRect? {
    guard let origin = point(kAXPositionAttribute), let size = size(kAXSizeAttribute) else { return nil }

    return CGRect(origin: origin, size: size)
  }

  @discardableResult
  func set(_ attribute: String, to value: Bool) -> AXError {
    AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean)
  }

  @discardableResult
  func press() -> AXError {
    AXUIElementPerformAction(element, kAXPressAction as CFString)
  }

  private func value(_ attribute: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }

    return value
  }

  private func point(_ attribute: String) -> CGPoint? {
    var point = CGPoint.zero
    guard let value = value(attribute), AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }

    return point
  }

  private func size(_ attribute: String) -> CGSize? {
    var size = CGSize.zero
    guard let value = value(attribute), AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }

    return size
  }
}
