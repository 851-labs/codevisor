import AppKit
import ApplicationServices
import Foundation

func computerUseResolvedDeliveryMode(
    requested: String,
    targetIsOnVisibleSpace: Bool?
) -> String? {
    guard requested == "background" || requested == "foreground" else { return nil }
    if requested == "background", targetIsOnVisibleSpace == false {
        return "foreground"
    }
    return requested
}

extension ComputerUseBridge {
    /// AX requests that target our own process run their side effects on the
    /// calling thread — a bridge worker, not main. A SwiftUI action invoked
    /// there trips main-actor isolation and kills the app, and an agent
    /// driving Codevisor itself (same pid) is a real, supported flow. Marshal
    /// those mutations onto the main thread; other processes are unaffected.
    /// The AX C types predate Sendable; this crossing is a synchronous hop to
    /// the main thread with the caller blocked, so nothing races.
    private struct UncheckedAXPayload<Value>: @unchecked Sendable {
        let value: Value
    }

    /// Dispatched, never `sync`: a self-targeted action can open a menu or
    /// sheet, and AppKit runs those in a nested tracking loop that would not
    /// return until the user dismissed it — blocking this worker (and the
    /// whole helper socket) for the duration. The effect is reported through
    /// the post-action snapshot instead of an AXError.
    func axPerformAction(
        _ element: AXUIElement,
        _ action: CFString,
        pid: pid_t
    ) -> AXError {
        guard pid == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread else {
            return AXUIElementPerformAction(element, action)
        }
        let payload = UncheckedAXPayload(value: (element, action))
        // Wait (on this worker thread, never main) until the main queue has
        // actually run the action before the caller snapshots. The timeout is
        // a safety valve for actions that open a nested tracking loop.
        let applied = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            _ = AXUIElementPerformAction(payload.value.0, payload.value.1)
            applied.signal()
        }
        _ = applied.wait(timeout: .now() + 2)
        return .success
    }

    func axSetAttribute(
        _ element: AXUIElement,
        _ attribute: CFString,
        _ value: CFTypeRef,
        pid: pid_t
    ) -> AXError {
        guard pid == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread else {
            return AXUIElementSetAttributeValue(element, attribute, value)
        }
        let payload = UncheckedAXPayload(value: (element, attribute, value))
        let applied = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            _ = AXUIElementSetAttributeValue(payload.value.0, payload.value.1, payload.value.2)
            applied.signal()
        }
        _ = applied.wait(timeout: .now() + 2)
        return .success
    }

    func performAccessibilityClick(
        target: ElementRecord,
        button: String,
        clickCount: Int,
        pid: pid_t
    ) throws -> String? {
        let desired: [String]
        switch button.lowercased() {
        case "right": desired = [kAXShowMenuAction as String]
        case "middle":
            throw BridgeError(
                "A semantic middle-click has no accessibility equivalent; use screenshot x/y"
            )
        default:
            desired = [
                kAXPressAction as String,
                kAXConfirmAction as String,
                "AXOpen",
            ]
        }
        let advertised = actionNames(of: target.element)
        guard
            let action = desired.first(where: { desiredAction in
                advertised.contains(where: {
                    $0.caseInsensitiveCompare(desiredAction) == .orderedSame
                })
            })
        else {
            return nil
        }
        for attempt in 0..<max(clickCount, 1) {
            guard axPerformAction(target.element, action as CFString, pid: pid) == .success else {
                throw BridgeError("The selected element rejected \(action)")
            }
            if attempt < clickCount - 1 { Thread.sleep(forTimeInterval: 0.05) }
        }
        Thread.sleep(forTimeInterval: 0.08)
        return action
    }

    /// Pop-up buttons do not always publish AXValue — a freshly built sheet
    /// often reports nothing — which leaves the model unable to read the
    /// current selection. Recover it from the selected child or the button's
    /// own label instead of showing an empty control.
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

    func deliveryMode(
        _ arguments: [String: Any],
        windowID: CGWindowID?
    ) throws -> String {
        let requested =
            (arguments["deliveryMode"] ?? arguments["delivery_mode"]) as? String
            ?? "background"
        let targetIsVisible = windowID.map(windowIsOnVisibleSpace)
        guard
            let resolved = computerUseResolvedDeliveryMode(
                requested: requested,
                targetIsOnVisibleSpace: targetIsVisible
            )
        else {
            throw BridgeError("deliveryMode must be background or foreground")
        }
        // PID-targeted events cannot be trusted to reach a window on an
        // inactive Space. Promote pointer/keyboard delivery to foreground in
        // that case; semantic Accessibility actions remain background-only.
        return resolved
    }

    func performWithDelivery<T>(
        app: NSRunningApplication,
        window: AXUIElement,
        windowID: CGWindowID?,
        mode: String,
        operation: () throws -> T
    ) throws -> T {
        if mode == "foreground" {
            return try withAppFronted(
                app: app,
                window: window,
                windowID: windowID,
                operation: operation
            )
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
            "verified": verified,
            "effect": verified ? "confirmed" : "unverifiable",
            "next": verified
                ? "The requested state was confirmed in the target accessibility object."
                : "Confirm the effect in the returned app state before continuing.",
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

    /// Notes and other rich editors expose their semantic formatting through
    /// AXAttributedStringForRange. Render the same lightweight markdown cues
    /// as native Computer Use so a model can distinguish title/heading/body
    /// text without guessing from screenshot pixels.
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
