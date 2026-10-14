import AppKit
import ApplicationServices
import Foundation

extension ComputerUseBridge {
  private struct UncheckedAXPayload<Value>: @unchecked Sendable {
    let value: Value
  }

  private final class AXMutationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var error: AXError = .cannotComplete
    func store(_ error: AXError) { lock.withLock { self.error = error } }
    func load() -> AXError { lock.withLock { error } }
  }

  func axPerformAction(
    _ element: AXUIElement,
    _ action: CFString,
    pid: pid_t
  ) -> AXError {
    let authorized = ComputerUseForeground.shared.authorization(pid: pid)
    guard authorized?() != false else { return .cannotComplete }
    guard pid == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread else {
      AXUIElementSetMessagingTimeout(element, 1)
      return AXUIElementPerformAction(element, action)
    }
    let payload = UncheckedAXPayload(value: (element, action))
    let applied = DispatchSemaphore(value: 0)
    let result = AXMutationResult()
    DispatchQueue.main.async {
      guard authorized?() != false else { applied.signal(); return }
      result.store(AXUIElementPerformAction(payload.value.0, payload.value.1))
      applied.signal()
    }
    return applied.wait(timeout: .now() + 2) == .success ? result.load() : .cannotComplete
  }

  func axSetAttribute(
    _ element: AXUIElement,
    _ attribute: CFString,
    _ value: CFTypeRef,
    pid: pid_t
  ) -> AXError {
    let authorized = ComputerUseForeground.shared.authorization(pid: pid)
    guard authorized?() != false else { return .cannotComplete }
    guard pid == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread else {
      AXUIElementSetMessagingTimeout(element, 1)
      return AXUIElementSetAttributeValue(element, attribute, value)
    }
    let payload = UncheckedAXPayload(value: (element, attribute, value))
    let applied = DispatchSemaphore(value: 0)
    let result = AXMutationResult()
    DispatchQueue.main.async {
      guard authorized?() != false else { applied.signal(); return }
      result.store(AXUIElementSetAttributeValue(payload.value.0, payload.value.1, payload.value.2))
      applied.signal()
    }
    return applied.wait(timeout: .now() + 2) == .success ? result.load() : .cannotComplete
  }

  func selectionDescription(of element: AXUIElement, role: String) -> String? {
    guard role == "AXPopUpButton" || role == "AXComboBox" else { return nil }
    if let selected = elementsAttribute(element, kAXSelectedChildrenAttribute).first,
      let title = stringAttribute(selected, kAXTitleAttribute) ?? stringAttribute(selected, kAXValueAttribute),
      !title.isEmpty
    {
      return title
    }
    for child in elementsAttribute(element, kAXChildrenAttribute) {
      if let text = stringAttribute(child, kAXValueAttribute)
        ?? stringAttribute(child, kAXTitleAttribute), !text.isEmpty
      {
        return text
      }
    }
    return nil
  }

  func actionNames(of element: AXUIElement) -> [String] {
    var pid: pid_t = 0
    let targetPID = AXUIElementGetPid(element, &pid) == .success ? pid : nil
    return computerUsePerformAccessibilityRead(targetPID: targetPID) {
      var names: CFArray?
      guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
      return names as? [String] ?? []
    }
  }

  func isSettable(_ element: AXUIElement, attribute: String) -> Bool {
    var pid: pid_t = 0
    let targetPID = AXUIElementGetPid(element, &pid) == .success ? pid : nil
    return computerUsePerformAccessibilityRead(targetPID: targetPID) {
      var settable = DarwinBoolean(false)
      return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        == .success
        && settable.boolValue
    }
  }

  func focus(element: AXUIElement, application: AXUIElement, pid: pid_t) throws {
    if isSettable(element, attribute: kAXFocusedAttribute),
      axSetAttribute(
        element,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue,
        pid: pid
      ) == .success
    {
      return
    }
    guard
      axSetAttribute(
        application,
        kAXFocusedUIElementAttribute as CFString,
        element,
        pid: pid
      ) == .success
    else {
      throw BridgeError("The selected element could not receive keyboard focus")
    }
  }

  func deliveryMode(_ arguments: [String: Any]) throws -> String {
    let requested =
      (arguments["deliveryMode"] ?? arguments["delivery_mode"]) as? String
      ?? "background"
    guard requested == "background" || requested == "foreground" else {
      throw BridgeError("deliveryMode must be background or foreground")
    }
    if requested == "foreground" {
      guard let reason = arguments["foreground_reason"] as? String,
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw BridgeError(
          "Foreground delivery requires foreground_reason explaining why background cannot complete this action.")
      }
    }
    return requested
  }

  func performWithDelivery<T>(
    app: NSRunningApplication,
    window: AXUIElement?,
    windowID: CGWindowID?,
    mode: String,
    sessionID: String,
    operation: () throws -> T
  ) throws -> T {
    if mode == "foreground" {
      return try ComputerUseForeground.shared.perform(
        sessionID: sessionID, pid: app.processIdentifier,
        hasOpenMenu: {
          guard let window else { return false }
          return self.openMenu(application: AXUIElementCreateApplication(app.processIdentifier), window: window) != nil
        }
      ) {
        guard let window else { return try operation() }
        return try withAppFronted(app: app, window: window, windowID: windowID, operation: operation)
      }
    }
    return try operation()
  }

  func actionResultMetadata(
    kind: String,
    path: String,
    deliveryMode: String? = nil,
    verified: Bool = false,
    detail: [String: Any] = [:]
  ) -> [String: Any] {
    var result: [String: Any] = [
      "kind": kind,
      "path": path,
      "delivered": true,
      "status": "delivered",
      "verified": verified,
      "effect": verified ? "confirmed" : "unverifiable",
      "next": verified
        ? "The requested state was confirmed in the target accessibility object."
        : "Delivery is not completion. Observe the result; for an animation or turn change, use wait_for before the next dependent action. Do not repeat or switch to foreground solely because delivery is unverified."
        ,
    ]
    if let deliveryMode { result["deliveryMode"] = deliveryMode }
    for (key, value) in detail { result[key] = value }
    return result
  }

  func textSelectionRange(
    element: AXUIElement,
    arguments: [String: Any]
  ) throws -> CFRange {
    guard isSettable(element, attribute: kAXSelectedTextRangeAttribute) else {
      throw BridgeError("The element does not expose a settable selected-text range")
    }
    guard let text = stringAttribute(element, kAXValueAttribute) else {
      throw BridgeError("The element does not expose an editable text value")
    }
    let value = text as NSString
    let fullLength = value.length
    var range: NSRange
    if arguments["all"] as? Bool == true {
      range = NSRange(location: 0, length: fullLength)
    } else if let needle = arguments["text"] as? String {
      let prefix = arguments["prefix"] as? String
      let suffix = arguments["suffix"] as? String
      var matches: [NSRange] = []
      var search = NSRange(location: 0, length: fullLength)
      while search.length >= 0 {
        let candidate = value.range(of: needle, options: [], range: search)
        if candidate.location == NSNotFound { break }
        let prefixMatches =
          prefix.map { expected in
            let expectedLength = (expected as NSString).length
            guard candidate.location >= expectedLength else { return false }
            return value.substring(
              with: NSRange(
                location: candidate.location - expectedLength,
                length: expectedLength
              )
            ) == expected
          } ?? true
        let suffixMatches =
          suffix.map { expected in
            let expectedLength = (expected as NSString).length
            let start = NSMaxRange(candidate)
            guard start + expectedLength <= fullLength else { return false }
            return value.substring(with: NSRange(location: start, length: expectedLength))
              == expected
          } ?? true
        if prefixMatches && suffixMatches { matches.append(candidate) }
        let next = candidate.location + max(candidate.length, 1)
        if next > fullLength { break }
        search = NSRange(location: next, length: fullLength - next)
      }
      guard !matches.isEmpty else {
        throw BridgeError("The requested text was not found in the element value")
      }
      guard matches.count == 1 else {
        throw BridgeError("The requested text occurs more than once; add prefix or suffix context")
      }
      range = matches[0]
    } else if let start = int(arguments["start"]), let length = int(arguments["length"]) {
      range = NSRange(location: start, length: length)
    } else {
      throw BridgeError("select_text requires all, text, or both start and length")
    }
    guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= fullLength else {
      throw BridgeError("The requested UTF-16 selection range is outside the editable value")
    }
    switch arguments["selectionType"] as? String ?? arguments["selection_type"] as? String
      ?? "text"
    {
    case "text", "range": break
    case "cursor_before": range.length = 0
    case "cursor_after": range.location = NSMaxRange(range); range.length = 0
    default: throw BridgeError("selectionType must be text, cursor_before, or cursor_after")
    }
    return CFRange(location: range.location, length: range.length)
  }

  func selectedTextRange(_ element: AXUIElement) -> CFRange? {
    guard let raw = copyAttribute(element, kAXSelectedTextRangeAttribute),
      CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
  }

  func formattedTextValue(element: AXUIElement, plainText: String) -> String? {
    let utf16Length = (plainText as NSString).length
    guard utf16Length > 0 else { return nil }
    var fullRange = CFRange(location: 0, length: utf16Length)
    guard let rangeValue = AXValueCreate(.cfRange, &fullRange) else { return nil }
    var pid: pid_t = 0
    let targetPID = AXUIElementGetPid(element, &pid) == .success ? pid : nil
    let raw: CFTypeRef? = computerUsePerformAccessibilityRead(targetPID: targetPID) {
      var value: CFTypeRef?
      guard
        AXUIElementCopyParameterizedAttributeValue(
          element,
          kAXAttributedStringForRangeParameterizedAttribute as CFString,
          rangeValue,
          &value
        ) == .success
      else { return nil }
      return value
    }
    guard let raw, CFGetTypeID(raw) == CFAttributedStringGetTypeID() else { return nil }
    let attributed = raw as! NSAttributedString
    let lines = plainText.components(separatedBy: "\n")
    var location = 0
    var foundFormatting = false
    let rendered = lines.map { text -> String in
      let index = min(max(0, location), max(0, attributed.length - 1))
      let attributes = attributed.attributes(at: index, effectiveRange: nil)
      location += (text as NSString).length + 1

      let font = attributes[NSAttributedString.Key("AXFont")] as? NSFont
      let fontDictionary =
        attributes[NSAttributedString.Key("AXFont")]
        as? [String: Any]
      let dictionarySize = (fontDictionary?["AXFontSize"] as? NSNumber)?.doubleValue
      let size =
        font?.pointSize
        ?? dictionarySize.map { CGFloat($0) }
        ?? 0
      let fontName = [
        font?.fontName,
        fontDictionary?["AXFontName"] as? String,
        fontDictionary?["AXFontDisplayName"] as? String,
      ].compactMap { $0 }.joined(separator: " ").lowercased()
      let bold =
        font?.fontDescriptor.symbolicTraits.contains(.bold) == true
        || fontName.contains("bold")
        || fontName.contains("semibold")
        || fontName.contains("heavy")

      if size >= 19.5 {
        foundFormatting = true
        return "# **\(text)**"
      }
      if bold, !text.isEmpty {
        foundFormatting = true
        return "**\(text)**"
      }
      return text
    }.joined(separator: "\n")
    return foundFormatting ? rendered : nil
  }
}
