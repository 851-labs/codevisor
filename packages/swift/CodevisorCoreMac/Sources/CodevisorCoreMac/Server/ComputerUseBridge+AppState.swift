import AppKit
import ApplicationServices
import Foundation

extension ComputerUseBridge {
    func appState(
        sessionID: String,
        agentLabel: String?,
        app name: String,
        requestedWindowID: CGWindowID? = nil,
        action: [String: Any]? = nil
    ) throws -> [String: Any] {
        try requireAccessibility(prompt: true)
        let app = try resolveApp(name)
        // Observing is the deliberate act that resumes an interrupted share.
        try ComputerUsePresentation.requireControlAllowed(
            sessionID: sessionID,
            pid: app.processIdentifier,
            resuming: true
        )
        let application = AXUIElementCreateApplication(app.processIdentifier)
        if let requestedWindowID {
            try selectSessionWindow(
                sessionID: sessionID,
                application: application,
                requestedWindowID: requestedWindowID
            )
        }
        let resolved: (element: AXUIElement, windowID: CGWindowID?)
        do {
            resolved = try sessionWindow(
                sessionID: sessionID,
                application: application,
                pid: app.processIdentifier
            )
        } catch {
            // A running app with every window closed (or on a Space that will
            // not come forward) has nothing to snapshot, but it is still
            // driveable: ⌘N is exactly how a person reopens a window. Report
            // that state instead of failing the call outright.
            return try windowlessAppState(
                app: app,
                name: name,
                detail: String(describing: error)
            )
        }
        let (window, windowID) = resolved
        activatePresentation(
            sessionID: sessionID,
            agentLabel: agentLabel,
            app: app,
            window: window,
            windowID: windowID
        )
        let snapshotID = UUID().uuidString
        let accessibilityWindowFrame = frame(of: window)
        // Never fronts the app: ScreenCaptureKit composites a window on
        // another Space perfectly well, so looking at an app must not steal
        // the user's focus or drag them between desktops.
        let outcome = screenshot(windowID: windowID, fallbackFrame: accessibilityWindowFrame)
        let capture = outcome.capture
        let windowFrame = capture?.windowFrame ?? frame(of: window) ?? accessibilityWindowFrame
        // For another app these calls are IPC and remain on this worker. For
        // Codevisor itself they synchronously enter AppKit/SwiftUI, so read the
        // complete tree in one main-thread hop. Screenshot capture above stays
        // off main because it waits on asynchronous ScreenCaptureKit work.
        let accessibility = computerUsePerformAccessibilityRead(
            targetPID: app.processIdentifier
        ) {
            var records: [String: ElementRecord] = [:]
            var lines: [String] = []
            // An app that publishes its content upside down would otherwise
            // send every coordinate — tree frames, the cursor, pointer events
            // — to the mirror image of the control that was named.
            let contentIsFlipped =
                windowFrame.map {
                    self.windowContentIsFlipped(
                        application: application,
                        window: window,
                        windowID: windowID,
                        windowFrame: $0
                    )
                } ?? false
            self.snapshotTree(
                window,
                depth: 0,
                screenshotWindowFrame: windowFrame,
                screenshotPixelSize: capture?.pixelSize,
                correctFrame: { element, reported in
                    guard contentIsFlipped, let windowFrame else { return reported }
                    return self.correctedFrame(
                        of: element,
                        reported: reported,
                        application: application,
                        windowFrame: windowFrame
                    )
                },
                records: &records,
                lines: &lines
            )
            return ComputerUseAppAccessibilityState(
                records: records,
                text: lines.joined(separator: "\n"),
                contentIsFlipped: contentIsFlipped,
                hasModalSheet: !self.sheetElements(of: window).isEmpty,
                windows: self.windowInventory(application: application, pinnedWindowID: windowID),
                windowTitle: stringAttribute(window, kAXTitleAttribute)
            )
        }
        lock.withLock {
            var session = snapshots[sessionID] ?? [:]
            session[snapshotID] = SnapshotRecord(
                elements: accessibility.records,
                windowID: windowID,
                windowFrame: windowFrame,
                screenshotPixelSize: capture?.pixelSize,
                createdAt: DispatchTime.now().uptimeNanoseconds
            )
            if session.count > 8,
                let oldest = session.min(by: { $0.value.createdAt < $1.value.createdAt })?.key
            {
                session.removeValue(forKey: oldest)
            }
            snapshots[sessionID] = session
            latestSnapshotIDs[sessionID] = snapshotID
        }
        let screenshotMetadata: [String: Any] =
            if capture == nil {
                ["available": false, "reason": outcome.reason ?? "No screenshot was produced."]
            } else {
                ["available": true]
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
            "text": accessibility.text,
            "accessibilityTree": accessibility.text,
            "screenshot": screenshotMetadata,
        ]
        // A modal sheet blocks every other control in the window, so say so
        // rather than leaving the model to infer it from the tree.
        if accessibility.contentIsFlipped {
            // Say so: the coordinates here will not match the app's own
            // accessibility inspector output.
            metadata["frameOrientationCorrected"] = true
        }
        if accessibility.hasModalSheet {
            metadata["modalSheetPresent"] = true
            metadata["next"] = "A modal dialog is open; dismiss or complete it before using other controls."
        }
        // The session follows one window. Publishing the rest is what makes an
        // action that opened a new window (⌘N) visible instead of looking like
        // it did nothing; windowId here can be passed back as window_id.
        let windows = accessibility.windows
        metadata["windows"] = windows
        if windows.count > 1,
            let focused = windows.first(where: { $0["isFocused"] as? Bool == true }),
            focused["isSessionWindow"] as? Bool != true,
            let focusedID = focused["windowId"]
        {
            metadata["focusedWindowId"] = focusedID
            metadata["next"] =
                "This app's focused window is not the one being inspected. Pass window_id \(focusedID) to switch to it."
        }
        if let windowID {
            metadata["windowId"] = Int(windowID)
            metadata["isOnActiveSpace"] = windowIsOnVisibleSpace(windowID)
        }
        if let title = accessibility.windowTitle { metadata["windowTitle"] = title }
        if let windowFrame { metadata["screenWindowBounds"] = frameObject(windowFrame) }
        if let action { metadata["action"] = action }
        if let pixelSize = capture?.pixelSize {
            metadata["screenshotSize"] = [
                "width": pixelSize.width,
                "height": pixelSize.height,
            ]
            metadata["windowBounds"] = [
                "x": 0,
                "y": 0,
                "width": pixelSize.width,
                "height": pixelSize.height,
            ]
            // windowBounds/screenshotSize are pixels while screenWindowBounds
            // is display points; publish the ratio so consumers can convert.
            if let windowFrame, windowFrame.width > 0 {
                metadata["scaleFactor"] = Double(pixelSize.width / windowFrame.width)
            }
        }
        var content: [[String: Any]] = [["type": "text", "text": try json(metadata)]]
        if let capture {
            content.append([
                "type": "image",
                "mimeType": "image/png",
                "data": capture.data.base64EncodedString(),
            ])
        }
        return ["content": content]
    }

    /// State for a running app that currently exposes no window. Keyboard
    /// tools still work (they address the process), so this is a recoverable
    /// state rather than an error.
    private func windowlessAppState(
        app: NSRunningApplication,
        name: String,
        detail: String
    ) throws -> [String: Any] {
        let metadata: [String: Any] = [
            "app": name,
            "resolvedApp": [
                "id": app.bundleIdentifier ?? app.bundleURL?.path ?? name,
                "name": app.localizedName ?? name,
                "path": app.bundleURL?.path ?? "",
                "pid": app.processIdentifier,
                "isRunning": true,
            ],
            "text": "",
            "accessibilityTree": "",
            "windows": [],
            "screenshot": [
                "available": false,
                "reason": "This app has no open window to capture. \(detail)",
            ],
            "next":
                "The app is running with no window. Press a key such as cmd+n to open one, then call get_app_state again.",
        ]
        return ["content": [["type": "text", "text": try json(metadata)]]]
    }

    private func snapshotTree(
        _ element: AXUIElement,
        depth: Int,
        screenshotWindowFrame: CGRect?,
        screenshotPixelSize: CGSize?,
        correctFrame: (AXUIElement, CGRect) -> CGRect = { _, frame in frame },
        records: inout [String: ElementRecord],
        lines: inout [String]
    ) {
        guard depth <= 64, records.count < 1_200 else { return }
        let id = String(records.count)
        let role = stringAttribute(element, kAXRoleAttribute) ?? "element"
        let title =
            stringAttribute(element, kAXTitleAttribute)
            ?? stringAttribute(element, kAXDescriptionAttribute)
            ?? ""
        let value =
            role.localizedCaseInsensitiveContains("secure")
            ? "<redacted>"
            : (stringAttribute(element, kAXValueAttribute)
                ?? selectionDescription(of: element, role: role)
                ?? "")
        let elementFrame = frame(of: element).map { correctFrame(element, $0) }
        records[id] = ElementRecord(element: element, frame: elementFrame)
        var line = "\(String(repeating: "\t", count: depth + 1))\(id) \(role) \(title)"
        // Menu containers report a placeholder frame (zero-sized, far offscreen)
        // while their items are correct. Publishing it invites a click into
        // nowhere, so only emit a frame that could actually be aimed at.
        if let elementFrame,
            elementFrame.width > 0,
            elementFrame.height > 0,
            let screenshotFrame = computerUseScreenshotFrame(
                screenFrame: elementFrame,
                screenshotPixelSize: screenshotPixelSize,
                windowFrame: screenshotWindowFrame
            )
        {
            line += " Frame: \(frameObject(screenshotFrame))"
        }
        let actions = actionNames(of: element)
        if !actions.isEmpty { line += " Actions: \(actions.joined(separator: ","))" }
        let settable = [
            kAXValueAttribute,
            kAXSelectedTextRangeAttribute,
            kAXFocusedAttribute,
        ].filter { isSettable(element, attribute: $0) }
        if !settable.isEmpty { line += " Settable: \(settable.joined(separator: ","))" }
        if !value.isEmpty, value != title {
            let rendered = formattedTextValue(element: element, plainText: value) ?? value
            line += " Value: \(String(rendered.prefix(4_000)))"
        }
        if let selectedRange = selectedTextRange(element), selectedRange.length > 0,
            !value.isEmpty, selectedRange.location >= 0,
            NSMaxRange(NSRange(location: selectedRange.location, length: selectedRange.length))
                <= (value as NSString).length
        {
            let selected = (value as NSString).substring(
                with: NSRange(location: selectedRange.location, length: selectedRange.length)
            )
            line += "\n\(String(repeating: "\t", count: depth + 1))Selected text: ```\n"
            line += "\(selected)\n``` Range: \(selectedRange.location):\(selectedRange.length)"
        }
        lines.append(line)
        for child in elementsAttribute(element, kAXChildrenAttribute) {
            snapshotTree(
                child,
                depth: depth + 1,
                screenshotWindowFrame: screenshotWindowFrame,
                screenshotPixelSize: screenshotPixelSize,
                correctFrame: correctFrame,
                records: &records,
                lines: &lines
            )
        }
    }
}

private struct ComputerUseAppAccessibilityState {
    let records: [String: ComputerUseBridge.ElementRecord]
    let text: String
    let contentIsFlipped: Bool
    let hasModalSheet: Bool
    let windows: [[String: Any]]
    let windowTitle: String?
}
