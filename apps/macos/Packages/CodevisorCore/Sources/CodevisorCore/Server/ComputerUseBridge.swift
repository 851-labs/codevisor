import AppKit
import ApplicationServices
import Darwin
import Foundation
import ScreenCaptureKit

private typealias CGEventSetWindowLocationFunction = @convention(c) (CGEvent, CGPoint) -> Void
private typealias SLEventPostToPidFunction = @convention(c) (pid_t, CGEvent) -> Void
private typealias SLEventSetIntegerValueFieldFunction = @convention(c) (CGEvent, UInt32, Int64) -> Void

// Stable AX-window to WindowServer identity. This SPI has remained available
// since macOS 10.9 and lets us avoid guessing by frame, which is especially
// important when the window lives on another Space. The same bridge is used by
// CUA's macOS driver (trycua/cua, b8a0f32a0).
@_silgen_name("_AXUIElementGetWindow")
private func AXUIElementGetWindowID(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

func computerUseWindowID(for element: AXUIElement) -> CGWindowID? {
    var windowID: CGWindowID = 0
    guard AXUIElementGetWindowID(element, &windowID) == .success, windowID != 0 else {
        return nil
    }
    return windowID
}

func computerUseWindowIsOnVisibleSpace(
    _ windowID: CGWindowID,
    windowInfo: [[String: Any]]
) -> Bool {
    windowInfo.contains { info in
        (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
    }
}

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

enum ComputerUseClickAddressing: Equatable {
    case semantic
    case pixel
    case ambiguous
    case invalid
}

struct ComputerUseChromiumClickStep: Equatable {
    enum Kind: Equatable {
        case move
        case down
        case up
    }

    let kind: Kind
    let point: CGPoint
    let windowPoint: CGPoint
    let phase: Int64
    let clickState: Int64
    let delayAfterMilliseconds: UInt32
}

func computerUseModifierFlag(named name: String) -> CGEventFlags? {
    switch name.lowercased() {
    case "cmd", "command", "meta", "super": .maskCommand
    case "ctrl", "control": .maskControl
    case "option", "alt": .maskAlternate
    case "shift": .maskShift
    default: nil
    }
}

func computerUseMouseButton(named name: String) -> String? {
    switch name.lowercased() {
    case "left", "l": "left"
    case "right", "r": "right"
    case "middle", "m": "middle"
    default: nil
    }
}

func computerUseClickAddressing(
    snapshotID: String?,
    elementID: String?,
    x: Double?,
    y: Double?
) -> ComputerUseClickAddressing {
    let hasSemanticTarget = elementID != nil
    let hasPixelTarget = x != nil || y != nil
    if hasSemanticTarget && hasPixelTarget { return .ambiguous }
    if snapshotID != nil, elementID != nil { return .semantic }
    if x != nil, y != nil { return .pixel }
    return .invalid
}

func computerUseUsesChromiumInput(
    appName: String?,
    bundleIdentifier: String?,
    executablePath: String?
) -> Bool {
    let identity = [appName, bundleIdentifier, executablePath]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    let chromiumIdentities = [
        "google chrome", "com.google.chrome", "chromium", "microsoft edge",
        "com.microsoft.edgemac", "brave browser", "com.brave.browser", "vivaldi",
        "com.vivaldi.vivaldi", "opera", "com.operasoftware.opera", "arc.app",
        "company.thebrowser.browser", "electron framework"
    ]
    return chromiumIdentities.contains(where: identity.contains)
}

struct ComputerUseApplicationIdentity: Equatable {
    let id: String
    let displayName: String
    let path: String
}

/// Native Computer Use accepts a display name, bundle identifier, or full app
/// path. Keep that matching logic independent from NSWorkspace so installed
/// and running app resolution cannot drift apart.
func computerUseApplicationMatchScore(
    query: String,
    identity: ComputerUseApplicationIdentity
) -> Int? {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    let expandedPath = (query as NSString).expandingTildeInPath.lowercased()
    let exactValues = [
        identity.id.lowercased(),
        identity.displayName.lowercased(),
        identity.path.lowercased(),
        URL(fileURLWithPath: identity.path).deletingPathExtension().lastPathComponent.lowercased()
    ]
    if exactValues.contains(normalized) || exactValues.contains(expandedPath) { return 0 }
    return identity.displayName.lowercased().contains(normalized) ? 1 : nil
}

func computerUseApplicationSearchRoots(homeDirectory: URL) -> [URL] {
    [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
        homeDirectory.appendingPathComponent("Applications", isDirectory: true)
    ]
}

func computerUseChromiumClickPlan(
    point: CGPoint,
    windowPoint: CGPoint,
    count: Int
) -> [ComputerUseChromiumClickStep] {
    var steps = [
        ComputerUseChromiumClickStep(
            kind: .move,
            point: point,
            windowPoint: windowPoint,
            phase: 2,
            clickState: 0,
            delayAfterMilliseconds: 15
        ),
        ComputerUseChromiumClickStep(
            kind: .down,
            point: CGPoint(x: -1, y: -1),
            windowPoint: CGPoint(x: -1, y: -1),
            phase: 1,
            clickState: 1,
            delayAfterMilliseconds: 1
        ),
        ComputerUseChromiumClickStep(
            kind: .up,
            point: CGPoint(x: -1, y: -1),
            windowPoint: CGPoint(x: -1, y: -1),
            phase: 2,
            clickState: 1,
            delayAfterMilliseconds: 100
        )
    ]
    let clickPairs = min(2, max(1, count))
    for clickState in 1...clickPairs {
        steps.append(ComputerUseChromiumClickStep(
            kind: .down,
            point: point,
            windowPoint: windowPoint,
            phase: 3,
            clickState: Int64(clickState),
            delayAfterMilliseconds: 1
        ))
        steps.append(ComputerUseChromiumClickStep(
            kind: .up,
            point: point,
            windowPoint: windowPoint,
            phase: 3,
            clickState: Int64(clickState),
            delayAfterMilliseconds: clickState < clickPairs ? 80 : 0
        ))
    }
    return steps
}

/*
 The Chromium WindowServer event sequence above is adapted from Cua
 (https://github.com/trycua/cua), commit
 b8a0f32a06c75225ba24ebb5ab14f6507fa90d15.

 MIT License

 Copyright (c) 2025 Cua AI, Inc.

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
*/

/// Small, dynamically-linked wrapper around the WindowServer event entry points
/// used by Chromium-class apps. Every caller retains the public CGEvent post as
/// a fallback, so an OS update that removes these symbols degrades cleanly.
private final class SkyLightEventBridge: @unchecked Sendable {
    static let shared = SkyLightEventBridge()

    private let postToPid: SLEventPostToPidFunction?
    private let setIntegerValueField: SLEventSetIntegerValueFieldFunction?
    private let setWindowLocation: CGEventSetWindowLocationFunction?

    private init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        let handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL)
        func resolve<T>(_ name: String, as type: T.Type) -> T? {
            let symbol = name.withCString { dlsym(handle, $0) }
            guard let symbol else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        postToPid = resolve("SLEventPostToPid", as: SLEventPostToPidFunction.self)
        setIntegerValueField = resolve(
            "SLEventSetIntegerValueField",
            as: SLEventSetIntegerValueFieldFunction.self
        )
        setWindowLocation = resolve(
            "CGEventSetWindowLocation",
            as: CGEventSetWindowLocationFunction.self
        )
    }

    var supportsTargetedPost: Bool { postToPid != nil }

    func setInteger(_ event: CGEvent, field: UInt32, value: Int64) {
        setIntegerValueField?(event, field, value)
    }

    func setWindowPoint(_ event: CGEvent, point: CGPoint) {
        setWindowLocation?(event, point)
    }

    func post(_ event: CGEvent, to pid: pid_t) {
        // The SkyLight post reaches Chromium's WindowServer path. The public
        // post remains necessary for AppKit/Catalyst targets that ignore it.
        postToPid?(pid, event)
        event.postToPid(pid)
    }
}

/// Authenticated, loopback-only Unix socket used by the bundled server for
/// macOS accessibility automation. The Node process never receives direct
/// Accessibility or Screen Recording entitlements; those stay in the app.
public final class ComputerUseBridge: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let socketPath: String
        public let token: String
    }

    private struct ElementRecord {
        let element: AXUIElement
        let frame: CGRect?
    }

    private struct SnapshotRecord {
        let elements: [String: ElementRecord]
        let windowID: CGWindowID?
        let windowFrame: CGRect?
        let screenshotPixelSize: CGSize?
        let createdAt: UInt64
    }

    private struct InstalledApplication {
        let identity: ComputerUseApplicationIdentity
        let url: URL
    }

    private final class ApplicationLaunchResult: @unchecked Sendable {
        private let lock = NSLock()
        private var application: NSRunningApplication?
        private var error: Error?

        func store(application: NSRunningApplication?, error: Error?) {
            lock.withLock {
                self.application = application
                self.error = error
            }
        }

        func load() -> (application: NSRunningApplication?, error: Error?) {
            lock.withLock { (application, error) }
        }
    }

    fileprivate struct ScreenshotCapture {
        let data: Data
        let pixelSize: CGSize
        let windowFrame: CGRect
    }

    private let listenerQueue = DispatchQueue(
        label: "com.codevisor.computer-use.listener",
        qos: .userInitiated
    )
    private let clientQueue = DispatchQueue(
        label: "com.codevisor.computer-use.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let supportDirectory: URL
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var configuration: Configuration?
    private var snapshots: [String: [String: SnapshotRecord]] = [:]
    private var latestSnapshotIDs: [String: String] = [:]
    private var windowIDBySession: [String: CGWindowID] = [:]

    public init(supportDirectory: URL = CodevisorAppVariant.serverDataDirectoryURL()) {
        self.supportDirectory = supportDirectory
    }

    deinit {
        stop()
    }

    public func start() throws -> Configuration {
        lock.lock()
        defer { lock.unlock() }
        if let configuration { return configuration }

        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // sockaddr_un paths are short (104 bytes on macOS), while development
        // data directories are often nested deeply in a worktree. Derive a
        // stable, user-scoped socket in the system temporary directory and
        // keep the durable authentication token beside the server database.
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codevisor-cu-\(getuid())-\(Self.stablePathHash(supportDirectory.path)).sock"
            ).path
        let tokenURL = supportDirectory.appendingPathComponent("computer-use-token")
        let token: String
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            token = existing
        } else {
            token = UUID().uuidString + UUID().uuidString
            try Data(token.utf8).write(to: tokenURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tokenURL.path
            )
        }

        unlink(socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        do {
            try bindSocket(descriptor, path: socketPath)
            guard listen(descriptor, 8) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        } catch {
            Darwin.close(descriptor)
            unlink(socketPath)
            throw error
        }
        chmod(socketPath, 0o600)
        listener = descriptor
        let ready = Configuration(socketPath: socketPath, token: token)
        configuration = ready
        listenerQueue.async { [weak self] in self?.acceptLoop(descriptor, token: token) }
        return ready
    }

    public func stop() {
        lock.lock()
        let descriptor = listener
        listener = -1
        let socketPath = configuration?.socketPath
        configuration = nil
        snapshots.removeAll()
        latestSnapshotIDs.removeAll()
        windowIDBySession.removeAll()
        lock.unlock()
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        if let socketPath { unlink(socketPath) }
        ComputerUsePresentation.endAll()
    }

    private func bindSocket(_ descriptor: Int32, path: String) throws {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            _ = path.utf8CString.withUnsafeBytes { source in
                source.copyBytes(to: bytes)
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, length)
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func acceptLoop(_ descriptor: Int32, token: String) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 { return }
            clientQueue.async { [weak self] in
                self?.serve(client, token: token)
                Darwin.close(client)
            }
        }
    }

    private static func stablePathHash(_ path: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(hash, radix: 16)
    }

    private func serve(_ descriptor: Int32, token: String) {
        var authenticated = false
        var activeSessionIDs = Set<String>()
        defer {
            for sessionID in activeSessionIDs {
                ComputerUsePresentation.end(sessionID: sessionID)
            }
        }
        var pending = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = recv(descriptor, &bytes, bytes.count, 0)
            if count <= 0 { return }
            pending.append(bytes, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                let response: [String: Any]
                do {
                    guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                    else { throw BridgeError("Invalid request") }
                    let id = message["id"] as? String ?? ""
                    if !authenticated {
                        guard message["type"] as? String == "authenticate",
                              message["token"] as? String == token
                        else { throw BridgeError("Authentication failed") }
                        authenticated = true
                        response = ["id": id, "result": textResult("authenticated")]
                    } else {
                        if let sessionID = message["sessionId"] as? String, !sessionID.isEmpty {
                            if message["type"] as? String == "closeSession" {
                                activeSessionIDs.remove(sessionID)
                            } else if message["type"] as? String == "tool" {
                                activeSessionIDs.insert(sessionID)
                            }
                        }
                        response = ["id": id, "result": try handle(message)]
                    }
                } catch {
                    let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                    response = [
                        "id": object?["id"] as? String ?? "",
                        "error": String(describing: error)
                    ]
                }
                guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
                writeAll(descriptor, data + Data([0x0A]))
            }
        }
    }

    private func handle(_ message: [String: Any]) throws -> [String: Any] {
        let type = message["type"] as? String
        let sessionID = message["sessionId"] as? String ?? ""
        let agentLabel = message["agentLabel"] as? String
        if type == "closeSession" {
            _ = lock.withLock { snapshots.removeValue(forKey: sessionID) }
            _ = lock.withLock { latestSnapshotIDs.removeValue(forKey: sessionID) }
            _ = lock.withLock { windowIDBySession.removeValue(forKey: sessionID) }
            ComputerUsePresentation.end(sessionID: sessionID)
            return textResult("closed")
        }
        guard type == "tool", let tool = message["tool"] as? String else {
            throw BridgeError("Unsupported helper request")
        }
        let arguments = message["arguments"] as? [String: Any] ?? [:]
        if tool == "list_apps" { return try listApps() }
        guard let appName = arguments["app"] as? String else {
            throw BridgeError("app is required")
        }
        if tool == "get_app_state" {
            return try appState(sessionID: sessionID, agentLabel: agentLabel, app: appName)
        }
        try requireAccessibility(prompt: true)
        let app = try resolveApp(appName)
        try ComputerUsePresentation.requireControlAllowed(
            sessionID: sessionID,
            pid: app.processIdentifier
        )
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let (window, windowID) = try sessionWindow(
            sessionID: sessionID,
            application: application,
            pid: app.processIdentifier
        )
        let target = try targetElement(sessionID: sessionID, arguments: arguments)
        activatePresentation(
            sessionID: sessionID,
            agentLabel: agentLabel,
            app: app,
            window: window,
            windowID: windowID
        )

        var actionMetadata: [String: Any]?
        switch tool {
        case "click":
            let clickCount = int(arguments["clickCount"] ?? arguments["click_count"]) ?? 1
            guard (1...2).contains(clickCount) else {
                throw BridgeError("clickCount must be 1 or 2")
            }
            let requestedButton = (arguments["button"] ?? arguments["mouse_button"]) as? String ?? "left"
            guard let button = computerUseMouseButton(named: requestedButton) else {
                throw BridgeError("button must be left, right, or middle")
            }
            let addressing = computerUseClickAddressing(
                snapshotID: ((arguments["snapshotId"] ?? arguments["snapshot_id"]) as? String)
                    ?? lock.withLock({ latestSnapshotIDs[sessionID] }),
                elementID: (arguments["elementId"] ?? arguments["element_index"]).map {
                    String(describing: $0)
                },
                x: double(arguments["x"]),
                y: double(arguments["y"])
            )
            switch addressing {
            case .semantic:
                guard let target else {
                    throw BridgeError("Unknown or expired element; call get_app_state again")
                }
                if let targetFrame = target.frame {
                    ComputerUsePresentation.moveCursor(
                        sessionID: sessionID,
                        to: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                    )
                }
                let accessibilityAction = try performAccessibilityClick(
                    target: target,
                    button: button,
                    clickCount: clickCount
                )
                let path: String
                if accessibilityAction != nil {
                    path = "accessibility"
                } else if let targetFrame = target.frame {
                    let windowFrame = frame(of: window)
                    let deliveryMode = try deliveryMode(arguments, windowID: windowID)
                    let performClick = {
                        try self.mouseClick(
                            CGPoint(x: targetFrame.midX, y: targetFrame.midY),
                            count: clickCount,
                            button: button,
                            pid: app.processIdentifier,
                            windowID: windowID,
                            windowFrame: windowFrame,
                            chromium: computerUseUsesChromiumInput(
                                appName: app.localizedName,
                                bundleIdentifier: app.bundleIdentifier,
                                executablePath: app.executableURL?.path
                            )
                        )
                    }
                    path = deliveryMode == "foreground"
                        ? try withAppFronted(
                            app: app,
                            window: window,
                            windowID: windowID,
                            operation: performClick
                        )
                        : try performClick()
                } else {
                    throw BridgeError(
                        "The selected element has no accessibility click action or onscreen frame"
                    )
                }
                if let targetFrame = target.frame {
                    ComputerUsePresentation.moveCursor(
                        sessionID: sessionID,
                        to: CGPoint(x: targetFrame.midX, y: targetFrame.midY),
                        pulse: true
                    )
                }
                var semanticMetadata: [String: Any] = [
                    "kind": "click",
                    "addressing": "element",
                    "path": path,
                    "delivered": true,
                    "verified": false,
                    "effect": "unverifiable",
                    "next": "Confirm the effect in the returned app state. Re-snapshot before another action."
                ]
                if let accessibilityAction {
                    semanticMetadata["accessibilityAction"] = accessibilityAction
                }
                actionMetadata = semanticMetadata
            case .pixel:
                let point = try screenPoint(
                    window: window,
                    target: nil,
                    sessionID: sessionID,
                    arguments: arguments
                )
                let windowFrame = frame(of: window)
                let deliveryMode = try deliveryMode(arguments, windowID: windowID)
                ComputerUsePresentation.moveCursor(sessionID: sessionID, to: point)
                let performClick = {
                    try self.mouseClick(
                        point,
                        count: clickCount,
                        button: button,
                        pid: app.processIdentifier,
                        windowID: windowID,
                        windowFrame: windowFrame,
                        chromium: computerUseUsesChromiumInput(
                            appName: app.localizedName,
                            bundleIdentifier: app.bundleIdentifier,
                            executablePath: app.executableURL?.path
                        )
                    )
                }
                let path: String
                if deliveryMode == "foreground" {
                    path = try withAppFronted(
                        app: app,
                        window: window,
                        windowID: windowID,
                        operation: performClick
                    )
                } else {
                    path = try performClick()
                }
                var pixelMetadata: [String: Any] = [
                    "kind": "click",
                    "addressing": "pixel",
                    "path": path,
                    "deliveryMode": deliveryMode,
                    "delivered": true,
                    "verified": false,
                    "effect": "unverifiable",
                    "screenshotPoint": [
                        "x": double(arguments["x"]) ?? 0,
                        "y": double(arguments["y"]) ?? 0
                    ],
                    "next": "Confirm the effect in the returned screenshot. If unchanged, re-snapshot and retry once with deliveryMode foreground or use Browser Use for web-page content."
                ]
                if let windowID { pixelMetadata["windowId"] = Int(windowID) }
                actionMetadata = pixelMetadata
                ComputerUsePresentation.moveCursor(sessionID: sessionID, to: point, pulse: true)
            case .ambiguous:
                throw BridgeError(
                    "Choose one click addressing mode: snapshotId + elementId, or screenshot x + y"
                )
            case .invalid:
                throw BridgeError(
                    "Click requires snapshotId + elementId, or both screenshot x and y coordinates"
                )
            }
        case "drag":
            let start = try dragPoint(
                prefix: "from",
                window: window,
                sessionID: sessionID,
                arguments: arguments
            )
            let end = try dragPoint(
                prefix: "to",
                window: window,
                sessionID: sessionID,
                arguments: arguments
            )
            ComputerUsePresentation.moveCursor(sessionID: sessionID, to: start)
            let mode = try deliveryMode(arguments, windowID: windowID)
            let path = try performWithDelivery(
                app: app,
                window: window,
                windowID: windowID,
                mode: mode
            ) {
                try self.drag(
                    from: start,
                    to: end,
                    pid: app.processIdentifier,
                    global: mode == "foreground"
                )
                return mode == "foreground" ? "cgevent_global" : "cgevent_pid"
            }
            ComputerUsePresentation.moveCursor(sessionID: sessionID, to: end, pulse: true)
            actionMetadata = actionResultMetadata(
                kind: "drag",
                path: path,
                deliveryMode: mode
            )
        case "perform_secondary_action":
            if let targetFrame = target?.frame {
                ComputerUsePresentation.moveCursor(
                    sessionID: sessionID,
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                )
            }
            guard let element = target?.element, let action = arguments["action"] as? String,
                  AXUIElementPerformAction(element, action as CFString) == .success
            else { throw BridgeError("That accessibility action is unavailable") }
            if let targetFrame = target?.frame {
                ComputerUsePresentation.moveCursor(
                    sessionID: sessionID,
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY),
                    pulse: true
                )
            }
            actionMetadata = actionResultMetadata(
                kind: "perform_secondary_action",
                path: "accessibility",
                detail: ["accessibilityAction": action]
            )
        case "press_key":
            guard let key = arguments["key"] as? String else { throw BridgeError("key is required") }
            let mode = try deliveryMode(arguments, windowID: windowID)
            let path = try performWithDelivery(
                app: app,
                window: window,
                windowID: windowID,
                mode: mode
            ) {
                try self.keyPress(key, pid: app.processIdentifier, global: mode == "foreground")
                return mode == "foreground" ? "cgevent_global" : "cgevent_pid"
            }
            actionMetadata = actionResultMetadata(
                kind: "press_key",
                path: path,
                deliveryMode: mode,
                detail: ["key": key]
            )
        case "scroll":
            let direction = arguments["direction"] as? String ?? "down"
            let pages = max(1, double(arguments["pages"]) ?? 1)
            let point = target?.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
                ?? frame(of: window).map { CGPoint(x: $0.midX, y: $0.midY) }
                ?? .zero
            ComputerUsePresentation.moveCursor(sessionID: sessionID, to: point)
            let mode = try deliveryMode(arguments, windowID: windowID)
            let path = try performWithDelivery(
                app: app,
                window: window,
                windowID: windowID,
                mode: mode
            ) {
                try self.scroll(
                    at: point,
                    direction: direction,
                    pages: pages,
                    pid: app.processIdentifier,
                    global: mode == "foreground"
                )
                return mode == "foreground" ? "cgevent_global" : "cgevent_pid"
            }
            actionMetadata = actionResultMetadata(
                kind: "scroll",
                path: path,
                deliveryMode: mode,
                detail: ["direction": direction, "pages": pages]
            )
        case "set_value":
            guard let element = target?.element, let value = arguments["value"] else {
                throw BridgeError("A current element and value are required")
            }
            if let targetFrame = target?.frame {
                ComputerUsePresentation.moveCursor(
                    sessionID: sessionID,
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                )
            }
            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
            else { throw BridgeError("The element is not settable") }
            let verified = copyAttribute(element, kAXValueAttribute).map {
                String(describing: $0)
            } == String(describing: value)
            actionMetadata = actionResultMetadata(
                kind: "set_value",
                path: "accessibility",
                verified: verified
            )
        case "type_text":
            if let element = target?.element { try focus(element: element, application: application) }
            guard let text = arguments["text"] as? String else { throw BridgeError("text is required") }
            if let targetFrame = target?.frame {
                ComputerUsePresentation.moveCursor(
                    sessionID: sessionID,
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                )
            }
            let mode = try deliveryMode(arguments, windowID: windowID)
            let path = try performWithDelivery(
                app: app,
                window: window,
                windowID: windowID,
                mode: mode
            ) {
                try self.typeText(text, pid: app.processIdentifier, global: mode == "foreground")
                return mode == "foreground" ? "cgevent_global" : "cgevent_pid"
            }
            actionMetadata = actionResultMetadata(
                kind: "type_text",
                path: path,
                deliveryMode: mode,
                detail: ["utf16Length": text.utf16.count]
            )
        case "select_text":
            guard let element = target?.element else { throw BridgeError("A current element is required") }
            if let targetFrame = target?.frame {
                ComputerUsePresentation.moveCursor(
                    sessionID: sessionID,
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                )
            }
            let selectedRange = try textSelectionRange(element: element, arguments: arguments)
            var range = selectedRange
            guard let value = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
            else { throw BridgeError("The element does not support text selection") }
            let actualRange = selectedTextRange(element)
            let verified = actualRange?.location == selectedRange.location
                && actualRange?.length == selectedRange.length
            actionMetadata = actionResultMetadata(
                kind: "select_text",
                path: "accessibility",
                verified: verified,
                detail: ["start": selectedRange.location, "length": selectedRange.length]
            )
        default:
            throw BridgeError("Unsupported Computer Use tool: \(tool)")
        }
        Thread.sleep(forTimeInterval: 0.12)
        return try appState(
            sessionID: sessionID,
            agentLabel: agentLabel,
            app: appName,
            action: actionMetadata
        )
    }

    private func listApps() throws -> [String: Any] {
        let running = controllableRunningApplications()
        var seen = Set<String>()
        var apps = installedApplications().map { application in
            seen.insert(application.identity.id.lowercased())
            return [
                "id": application.identity.id,
                "displayName": application.identity.displayName,
                "isRunning": running.contains(where: {
                    computerUseApplicationMatchScore(
                        query: application.identity.id,
                        identity: runningIdentity($0)
                    ) == 0
                })
            ] as [String: Any]
        }
        // Include running apps outside the standard install roots (development
        // builds and apps launched from mounted volumes are common examples).
        for app in running {
            let identity = runningIdentity(app)
            guard seen.insert(identity.id.lowercased()).inserted else { continue }
            apps.append([
                "id": identity.id,
                "displayName": identity.displayName,
                "isRunning": true
            ])
        }
        apps = apps
            .sorted { String(describing: $0["displayName"]).localizedCaseInsensitiveCompare(String(describing: $1["displayName"])) == .orderedAscending }
        return textResult(try json(apps))
    }

    private func controllableRunningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated
                && $0.activationPolicy == .regular
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    private func runningIdentity(_ app: NSRunningApplication) -> ComputerUseApplicationIdentity {
        let path = app.bundleURL?.path ?? app.executableURL?.path ?? ""
        let displayName = app.localizedName
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? app.bundleIdentifier
            ?? "App"
        return ComputerUseApplicationIdentity(
            id: app.bundleIdentifier ?? (path.isEmpty ? String(app.processIdentifier) : path),
            displayName: displayName,
            path: path
        )
    }

    private func installedApplication(at url: URL) -> InstalledApplication? {
        let standardized = url.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: standardized)
        else { return nil }
        let info = bundle.infoDictionary ?? [:]
        guard info["LSBackgroundOnly"] as? Bool != true,
              info["LSUIElement"] as? Bool != true
        else { return nil }
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info[kCFBundleNameKey as String] as? String)
            ?? standardized.deletingPathExtension().lastPathComponent
        let identity = ComputerUseApplicationIdentity(
            id: bundle.bundleIdentifier ?? standardized.path,
            displayName: displayName,
            path: standardized.path
        )
        return InstalledApplication(identity: identity, url: standardized)
    }

    private func installedApplications() -> [InstalledApplication] {
        var urls = Set<URL>()
        for app in controllableRunningApplications() {
            if let url = app.bundleURL { urls.insert(url.standardizedFileURL) }
        }
        for root in computerUseApplicationSearchRoots(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ) where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                urls.insert(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        var byIdentity: [String: InstalledApplication] = [:]
        for application in urls.compactMap(installedApplication(at:)) {
            byIdentity[application.identity.id.lowercased()] = application
        }
        return byIdentity.values.sorted {
            $0.identity.displayName.localizedCaseInsensitiveCompare($1.identity.displayName)
                == .orderedAscending
        }
    }

    private func appState(
        sessionID: String,
        agentLabel: String?,
        app name: String,
        action: [String: Any]? = nil
    ) throws -> [String: Any] {
        try requireAccessibility(prompt: true)
        let app = try resolveApp(name)
        try ComputerUsePresentation.requireControlAllowed(
            sessionID: sessionID,
            pid: app.processIdentifier
        )
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let (window, windowID) = try sessionWindow(
            sessionID: sessionID,
            application: application,
            pid: app.processIdentifier
        )
        activatePresentation(
            sessionID: sessionID,
            agentLabel: agentLabel,
            app: app,
            window: window,
            windowID: windowID
        )
        let snapshotID = UUID().uuidString
        var records: [String: ElementRecord] = [:]
        var lines: [String] = []
        let accessibilityWindowFrame = frame(of: window)
        let capture = screenshot(windowID: windowID, fallbackFrame: accessibilityWindowFrame)
        let windowFrame = capture?.windowFrame ?? accessibilityWindowFrame
        snapshotTree(
            window,
            depth: 0,
            screenshotWindowFrame: windowFrame,
            screenshotPixelSize: capture?.pixelSize,
            records: &records,
            lines: &lines
        )
        lock.withLock {
            var session = snapshots[sessionID] ?? [:]
            session[snapshotID] = SnapshotRecord(
                elements: records,
                windowID: windowID,
                windowFrame: windowFrame,
                screenshotPixelSize: capture?.pixelSize,
                createdAt: DispatchTime.now().uptimeNanoseconds
            )
            if session.count > 8,
               let oldest = session.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
                session.removeValue(forKey: oldest)
            }
            snapshots[sessionID] = session
            latestSnapshotIDs[sessionID] = snapshotID
        }
        let accessibilityText = lines.joined(separator: "\n")
        var metadata: [String: Any] = [
            "snapshotId": snapshotID,
            "app": name,
            "resolvedApp": [
                "id": app.bundleIdentifier ?? app.bundleURL?.path ?? name,
                "name": app.localizedName ?? name,
                "path": app.bundleURL?.path ?? "",
                "pid": app.processIdentifier,
                "isRunning": true
            ],
            "text": accessibilityText,
            "accessibilityTree": accessibilityText,
            "screenshot": capture == nil ? NSNull() : ["available": true]
        ]
        if let windowID {
            metadata["windowId"] = Int(windowID)
            metadata["isOnActiveSpace"] = windowIsOnVisibleSpace(windowID)
        }
        if let title = stringAttribute(window, kAXTitleAttribute) { metadata["windowTitle"] = title }
        if let windowFrame { metadata["screenWindowBounds"] = frameObject(windowFrame) }
        if let action { metadata["action"] = action }
        if let pixelSize = capture?.pixelSize {
            metadata["screenshotSize"] = [
                "width": pixelSize.width,
                "height": pixelSize.height
            ]
            metadata["windowBounds"] = [
                "x": 0,
                "y": 0,
                "width": pixelSize.width,
                "height": pixelSize.height
            ]
        }
        var content: [[String: Any]] = [["type": "text", "text": try json(metadata)]]
        if let capture {
            content.append([
                "type": "image",
                "mimeType": "image/png",
                "data": capture.data.base64EncodedString()
            ])
        }
        return ["content": content]
    }

    private func snapshotTree(
        _ element: AXUIElement,
        depth: Int,
        screenshotWindowFrame: CGRect?,
        screenshotPixelSize: CGSize?,
        records: inout [String: ElementRecord],
        lines: inout [String]
    ) {
        guard depth <= 64, records.count < 1_200 else { return }
        let id = String(records.count)
        let role = stringAttribute(element, kAXRoleAttribute) ?? "element"
        let title = stringAttribute(element, kAXTitleAttribute)
            ?? stringAttribute(element, kAXDescriptionAttribute)
            ?? ""
        let value = role.localizedCaseInsensitiveContains("secure")
            ? "<redacted>"
            : (stringAttribute(element, kAXValueAttribute) ?? "")
        let elementFrame = frame(of: element)
        records[id] = ElementRecord(element: element, frame: elementFrame)
        var line = "\(String(repeating: "\t", count: depth + 1))\(id) \(role) \(title)"
        if let elementFrame,
           let screenshotFrame = computerUseScreenshotFrame(
               screenFrame: elementFrame,
               screenshotPixelSize: screenshotPixelSize,
               windowFrame: screenshotWindowFrame
           ) {
            line += " Frame: \(frameObject(screenshotFrame))"
        }
        let actions = actionNames(of: element)
        if !actions.isEmpty { line += " Actions: \(actions.joined(separator: ","))" }
        let settable = [
            kAXValueAttribute,
            kAXSelectedTextRangeAttribute,
            kAXFocusedAttribute
        ].filter { isSettable(element, attribute: $0) }
        if !settable.isEmpty { line += " Settable: \(settable.joined(separator: ","))" }
        if !value.isEmpty, value != title {
            let rendered = formattedTextValue(element: element, plainText: value) ?? value
            line += " Value: \(String(rendered.prefix(4_000)))"
        }
        if let selectedRange = selectedTextRange(element), selectedRange.length > 0,
           !value.isEmpty, selectedRange.location >= 0,
           NSMaxRange(NSRange(location: selectedRange.location, length: selectedRange.length))
             <= (value as NSString).length {
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
                records: &records,
                lines: &lines
            )
        }
    }

    private func resolveApp(_ query: String) throws -> NSRunningApplication {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw BridgeError("app is required") }
        if let pid = pid_t(normalized),
           let exactPID = controllableRunningApplications().first(where: {
               $0.processIdentifier == pid
           }) {
            return try requireUnprotected(exactPID)
        }

        let runningMatches = controllableRunningApplications().compactMap { app -> (NSRunningApplication, Int)? in
            computerUseApplicationMatchScore(query: normalized, identity: runningIdentity(app))
                .map { (app, $0) }
        }
        if let exact = runningMatches.first(where: { $0.1 == 0 })?.0 {
            return try requireUnprotected(exact)
        }
        let fuzzyRunning = runningMatches.filter { $0.1 == 1 }
        if fuzzyRunning.count == 1, let app = fuzzyRunning.first?.0 {
            return try requireUnprotected(app)
        }

        var candidates = installedApplications()
        let expandedPath = (normalized as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedPath),
           let direct = installedApplication(at: URL(fileURLWithPath: expandedPath)) {
            candidates.insert(direct, at: 0)
        }
        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalized),
           let direct = installedApplication(at: bundleURL) {
            candidates.insert(direct, at: 0)
        }
        let installedMatches = candidates.compactMap { application -> (InstalledApplication, Int)? in
            computerUseApplicationMatchScore(query: normalized, identity: application.identity)
                .map { (application, $0) }
        }
        let exactInstalled = installedMatches.filter { $0.1 == 0 }.map { $0.0 }
        let selected: InstalledApplication
        if let first = exactInstalled.first {
            selected = first
        } else {
            let fuzzyInstalled = installedMatches.filter { $0.1 == 1 }.map { $0.0 }
            guard fuzzyInstalled.count == 1, let first = fuzzyInstalled.first else {
                throw BridgeError(
                    fuzzyInstalled.isEmpty ? "App not found: \(query)" : "App name is ambiguous"
                )
            }
            selected = first
        }
        try requireUnprotected(selected.identity)
        return try launchApplication(selected)
    }

    private func launchApplication(_ application: InstalledApplication) throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = true
        configuration.createsNewApplicationInstance = false
        let completed = DispatchSemaphore(value: 0)
        let result = ApplicationLaunchResult()
        NSWorkspace.shared.openApplication(at: application.url, configuration: configuration) {
            launched, error in
            result.store(application: launched, error: error)
            completed.signal()
        }
        let deadline = DispatchTime.now() + 10
        if completed.wait(timeout: deadline) == .timedOut {
            throw BridgeError("Timed out launching \(application.identity.displayName)")
        }
        let launchResult = result.load()
        if let openError = launchResult.error {
            throw BridgeError(
                "Unable to launch \(application.identity.displayName): \(openError.localizedDescription)"
            )
        }
        if let openedApplication = launchResult.application {
            return try requireUnprotected(openedApplication)
        }
        for _ in 0..<50 {
            if let running = controllableRunningApplications().first(where: {
                computerUseApplicationMatchScore(
                    query: application.identity.id,
                    identity: runningIdentity($0)
                ) == 0
            }) {
                return try requireUnprotected(running)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw BridgeError("\(application.identity.displayName) launched without a running app")
    }

    private func requireUnprotected(_ identity: ComputerUseApplicationIdentity) throws {
        let normalized = [identity.displayName, identity.id, identity.path]
            .joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let protected = [
            "codevisor", "1password", "com.agilebits", "bitwarden", "lastpass",
            "dashlane", "keeper", "keychainaccess", "com.apple.passwords"
        ]
        if protected.contains(where: normalized.contains) {
            throw BridgeError("That app is protected and cannot be controlled by Computer Use")
        }
    }

    private func requireUnprotected(_ app: NSRunningApplication) throws -> NSRunningApplication {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            throw BridgeError("That app is protected and cannot be controlled by Computer Use")
        }
        try requireUnprotected(runningIdentity(app))
        return app
    }

    private func mainWindow(_ application: AXUIElement) throws -> AXUIElement {
        let candidates = [
            elementAttribute(application, kAXFocusedWindowAttribute),
            elementAttribute(application, kAXMainWindowAttribute)
        ].compactMap { $0 } + elementsAttribute(application, kAXWindowsAttribute)
        if let window = candidates.first(where: { candidate in
            stringAttribute(candidate, kAXRoleAttribute) == (kAXWindowRole as String)
        }) {
            return window
        }
        throw BridgeError("The app has no accessible window")
    }

    /// Keep a session attached to one composited window even if another Space
    /// changes the app's focused/main window. If that window closes, fall back
    /// to the app's current main window and establish a new identity.
    private func sessionWindow(
        sessionID: String,
        application: AXUIElement,
        pid: pid_t
    ) throws -> (element: AXUIElement, windowID: CGWindowID?) {
        var lastError: Error?
        // A successful LaunchServices completion only means the process is
        // running. Native Computer Use waits for the first accessible window
        // before returning state, so allow normal app startup to settle here.
        for attempt in 0..<80 {
            do {
                return try availableSessionWindow(
                    sessionID: sessionID,
                    application: application,
                    pid: pid
                )
            } catch {
                lastError = error
                if attempt < 79 { Thread.sleep(forTimeInterval: 0.1) }
            }
        }
        throw lastError ?? BridgeError("The app has no accessible window")
    }

    private func availableSessionWindow(
        sessionID: String,
        application: AXUIElement,
        pid: pid_t
    ) throws -> (element: AXUIElement, windowID: CGWindowID?) {
        let pinnedID = lock.withLock { windowIDBySession[sessionID] }
        if let pinnedID,
           let pinned = elementsAttribute(application, kAXWindowsAttribute).first(where: {
               computerUseWindowID(for: $0) == pinnedID
           }) {
            return (pinned, pinnedID)
        }

        let window = try mainWindow(application)
        let windowID = computerUseWindowID(for: window)
            ?? frame(of: window).flatMap { matchingWindowID(pid: pid, frame: $0) }
        lock.withLock {
            if let windowID {
                windowIDBySession[sessionID] = windowID
            } else {
                windowIDBySession.removeValue(forKey: sessionID)
            }
        }
        return (window, windowID)
    }

    private func targetElement(sessionID: String, arguments: [String: Any]) throws -> ElementRecord? {
        let explicitSnapshotID = (arguments["snapshotId"] ?? arguments["snapshot_id"]) as? String
        let snapshotID = explicitSnapshotID ?? lock.withLock { latestSnapshotIDs[sessionID] }
        let elementID = (arguments["elementId"] ?? arguments["element_index"]).map {
            String(describing: $0)
        }
        guard let snapshotID, let elementID, !elementID.isEmpty else { return nil }
        guard let record = lock.withLock({ snapshots[sessionID]?[snapshotID]?.elements[elementID] }) else {
            throw BridgeError("Unknown or expired element; call get_app_state again")
        }
        return record
    }

    private func screenPoint(
        window: AXUIElement,
        target: ElementRecord?,
        sessionID: String,
        arguments: [String: Any]
    ) throws -> CGPoint {
        if let frame = target?.frame { return CGPoint(x: frame.midX, y: frame.midY) }
        guard let frame = frame(of: window), let x = double(arguments["x"]), let y = double(arguments["y"])
        else { throw BridgeError("A current element or screenshot x/y coordinate is required") }
        return screenshotPoint(
            x: x,
            y: y,
            fallbackWindowFrame: frame,
            sessionID: sessionID,
            snapshotID: (arguments["snapshotId"] ?? arguments["snapshot_id"]) as? String
        )
    }

    private func dragPoint(prefix: String, window: AXUIElement, sessionID: String, arguments: [String: Any]) throws -> CGPoint {
        let camelKey = prefix + "ElementId"
        let snakeKey = prefix + "_element_index"
        if let rawID = arguments[camelKey] ?? arguments[snakeKey] {
            let id = String(describing: rawID)
            let snapshotID = ((arguments["snapshotId"] ?? arguments["snapshot_id"]) as? String)
                ?? lock.withLock({ latestSnapshotIDs[sessionID] })
            if !id.isEmpty, let snapshotID,
               let frame = lock.withLock({ snapshots[sessionID]?[snapshotID]?.elements[id]?.frame }) {
                return CGPoint(x: frame.midX, y: frame.midY)
            }
        }
        guard let frame = frame(of: window),
              let x = double(arguments[prefix + "X"] ?? arguments[prefix + "_x"]),
              let y = double(arguments[prefix + "Y"] ?? arguments[prefix + "_y"])
        else { throw BridgeError("Drag endpoints require current elements or coordinates") }
        return screenshotPoint(
            x: x,
            y: y,
            fallbackWindowFrame: frame,
            sessionID: sessionID,
            snapshotID: (arguments["snapshotId"] ?? arguments["snapshot_id"]) as? String
        )
    }

    private func screenshotPoint(
        x: Double,
        y: Double,
        fallbackWindowFrame: CGRect,
        sessionID: String,
        snapshotID: String?
    ) -> CGPoint {
        let snapshot = snapshotID.flatMap { id in
            lock.withLock { snapshots[sessionID]?[id] }
        } ?? lock.withLock {
            latestSnapshotIDs[sessionID].flatMap { snapshots[sessionID]?[$0] }
        }
        let windowFrame = snapshot?.windowFrame ?? fallbackWindowFrame
        return computerUseScreenshotPoint(
            x: x,
            y: y,
            screenshotPixelSize: snapshot?.screenshotPixelSize,
            windowFrame: windowFrame
        )
    }

    private func activatePresentation(
        sessionID: String,
        agentLabel: String?,
        app: NSRunningApplication,
        window: AXUIElement,
        windowID: CGWindowID?
    ) {
        guard let windowFrame = frame(of: window) else { return }
        ComputerUsePresentation.activate(
            sessionID: sessionID,
            agentLabel: agentLabel,
            appName: app.localizedName ?? app.bundleIdentifier ?? "App",
            pid: app.processIdentifier,
            windowID: windowID,
            windowFrame: windowFrame
        )
    }

    private func performAccessibilityClick(
        target: ElementRecord,
        button: String,
        clickCount: Int
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
                "AXOpen"
            ]
        }
        let advertised = actionNames(of: target.element)
        guard let action = desired.first(where: { desiredAction in
            advertised.contains(where: {
                $0.caseInsensitiveCompare(desiredAction) == .orderedSame
            })
        }) else {
            return nil
        }
        for attempt in 0..<max(clickCount, 1) {
            guard AXUIElementPerformAction(target.element, action as CFString) == .success else {
                throw BridgeError("The selected element rejected \(action)")
            }
            if attempt < clickCount - 1 { Thread.sleep(forTimeInterval: 0.05) }
        }
        Thread.sleep(forTimeInterval: 0.08)
        return action
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func isSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private func focus(element: AXUIElement, application: AXUIElement) throws {
        if isSettable(element, attribute: kAXFocusedAttribute),
           AXUIElementSetAttributeValue(
               element,
               kAXFocusedAttribute as CFString,
               kCFBooleanTrue
           ) == .success {
            return
        }
        guard AXUIElementSetAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            element
        ) == .success else {
            throw BridgeError("The selected element could not receive keyboard focus")
        }
    }

    private func deliveryMode(
        _ arguments: [String: Any],
        windowID: CGWindowID?
    ) throws -> String {
        let requested = (arguments["deliveryMode"] ?? arguments["delivery_mode"]) as? String
            ?? "background"
        let targetIsVisible = windowID.map(windowIsOnVisibleSpace)
        guard let resolved = computerUseResolvedDeliveryMode(
            requested: requested,
            targetIsOnVisibleSpace: targetIsVisible
        ) else {
            throw BridgeError("deliveryMode must be background or foreground")
        }
        // PID-targeted events cannot be trusted to reach a window on an
        // inactive Space. Promote pointer/keyboard delivery to foreground in
        // that case; semantic Accessibility actions remain background-only.
        return resolved
    }

    private func performWithDelivery<T>(
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

    private func actionResultMetadata(
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
                : "Confirm the effect in the returned app state before continuing."
        ]
        if let deliveryMode { result["deliveryMode"] = deliveryMode }
        for (key, value) in detail { result[key] = value }
        return result
    }

    private func textSelectionRange(
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
                let prefixMatches = prefix.map { expected in
                    let expectedLength = (expected as NSString).length
                    guard candidate.location >= expectedLength else { return false }
                    return value.substring(
                        with: NSRange(
                            location: candidate.location - expectedLength,
                            length: expectedLength
                        )
                    ) == expected
                } ?? true
                let suffixMatches = suffix.map { expected in
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
            ?? "text" {
        case "text", "range": break
        case "cursor_before": range.length = 0
        case "cursor_after": range.location = NSMaxRange(range); range.length = 0
        default: throw BridgeError("selectionType must be text, cursor_before, or cursor_after")
        }
        return CFRange(location: range.location, length: range.length)
    }

    private func selectedTextRange(_ element: AXUIElement) -> CFRange? {
        guard let raw = copyAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
    }

    /// Notes and other rich editors expose their semantic formatting through
    /// AXAttributedStringForRange. Render the same lightweight markdown cues
    /// as native Computer Use so a model can distinguish title/heading/body
    /// text without guessing from screenshot pixels.
    private func formattedTextValue(element: AXUIElement, plainText: String) -> String? {
        let utf16Length = (plainText as NSString).length
        guard utf16Length > 0 else { return nil }
        var fullRange = CFRange(location: 0, length: utf16Length)
        guard let rangeValue = AXValueCreate(.cfRange, &fullRange) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &raw
        ) == .success,
        let raw,
        CFGetTypeID(raw) == CFAttributedStringGetTypeID()
        else { return nil }
        let attributed = raw as! NSAttributedString
        let lines = plainText.components(separatedBy: "\n")
        var location = 0
        var foundFormatting = false
        let rendered = lines.map { text -> String in
            let index = min(max(0, location), max(0, attributed.length - 1))
            let attributes = attributed.attributes(at: index, effectiveRange: nil)
            location += (text as NSString).length + 1

            let font = attributes[NSAttributedString.Key("AXFont")] as? NSFont
            let fontDictionary = attributes[NSAttributedString.Key("AXFont")]
                as? [String: Any]
            let dictionarySize = (fontDictionary?["AXFontSize"] as? NSNumber)?.doubleValue
            let size = font?.pointSize
                ?? dictionarySize.map { CGFloat($0) }
                ?? 0
            let fontName = [
                font?.fontName,
                fontDictionary?["AXFontName"] as? String,
                fontDictionary?["AXFontDisplayName"] as? String
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            let bold = font?.fontDescriptor.symbolicTraits.contains(.bold) == true
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

    private func matchingWindowID(pid: pid_t, frame: CGRect) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return windows.compactMap { info -> (id: CGWindowID, overlap: CGFloat)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let candidate = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            let overlap = candidate.intersection(frame)
            return (number.uint32Value, overlap.width * overlap.height)
        }
        .max(by: { $0.overlap < $1.overlap })?.id
    }

    private func mouseClick(
        _ point: CGPoint,
        count: Int,
        button: String,
        pid: pid_t,
        windowID: CGWindowID?,
        windowFrame: CGRect?,
        chromium: Bool
    ) throws -> String {
        if chromium, button.caseInsensitiveCompare("left") == .orderedSame {
            guard let windowID, let windowFrame else {
                throw BridgeError(
                    "Chromium pixel delivery needs a visible target window. Restore the window and call get_app_state again."
                )
            }
            return try chromiumMouseClick(
                point,
                count: count,
                pid: pid,
                windowID: windowID,
                windowFrame: windowFrame
            )
        }
        let eventTypes: (down: CGEventType, up: CGEventType, button: CGMouseButton)
        switch button.lowercased() {
        case "right": eventTypes = (.rightMouseDown, .rightMouseUp, .right)
        case "middle": eventTypes = (.otherMouseDown, .otherMouseUp, .center)
        default: eventTypes = (.leftMouseDown, .leftMouseUp, .left)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw BridgeError("Unable to create targeted mouse event source")
        }
        let groupID = Int64(DispatchTime.now().uptimeNanoseconds & UInt64(Int64.max))
        for clickIndex in 1...max(1, count) {
            guard let moved = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: eventTypes.button),
                  let down = CGEvent(mouseEventSource: source, mouseType: eventTypes.down, mouseCursorPosition: point, mouseButton: eventTypes.button),
                  let up = CGEvent(mouseEventSource: source, mouseType: eventTypes.up, mouseCursorPosition: point, mouseButton: eventTypes.button)
            else { throw BridgeError("Unable to create mouse event") }
            for (event, clickState, phase) in [
                (moved, 0, 2),
                (down, clickIndex, 3),
                (up, clickIndex, 3)
            ] {
                configureTargetedMouseEvent(
                    event,
                    point: point,
                    button: eventTypes.button,
                    clickState: clickState,
                    windowID: windowID,
                    windowFrame: windowFrame,
                    pid: pid,
                    groupID: groupID,
                    phase: Int64(phase)
                )
                SkyLightEventBridge.shared.post(event, to: pid)
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        return SkyLightEventBridge.shared.supportsTargetedPost
            ? "skylight_pid"
            : "cgevent_pid"
    }

    private func configureTargetedMouseEvent(
        _ event: CGEvent,
        point: CGPoint,
        button: CGMouseButton,
        clickState: Int,
        windowID: CGWindowID?,
        windowFrame: CGRect?,
        pid: pid_t,
        groupID: Int64,
        phase: Int64 = 3,
        windowPoint: CGPoint? = nil
    ) {
        let skyLight = SkyLightEventBridge.shared
        event.location = point
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        skyLight.setInteger(event, field: 0, value: phase)
        skyLight.setInteger(event, field: 1, value: Int64(clickState))
        skyLight.setInteger(event, field: 3, value: Int64(button.rawValue))
        skyLight.setInteger(event, field: 7, value: 3)
        skyLight.setInteger(event, field: 40, value: Int64(pid))
        skyLight.setInteger(event, field: 58, value: groupID)
        guard let windowID else { return }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: Int64(windowID)
        )
        skyLight.setInteger(event, field: 51, value: Int64(windowID))
        skyLight.setInteger(event, field: 91, value: Int64(windowID))
        skyLight.setInteger(event, field: 92, value: Int64(windowID))
        guard let windowFrame else { return }
        skyLight.setWindowPoint(
            event,
            point: windowPoint
                ?? CGPoint(x: point.x - windowFrame.minX, y: point.y - windowFrame.minY)
        )
    }

    private func chromiumMouseClick(
        _ point: CGPoint,
        count: Int,
        pid: pid_t,
        windowID: CGWindowID,
        windowFrame: CGRect
    ) throws -> String {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw BridgeError("Unable to create Chromium mouse event source")
        }
        let windowPoint = CGPoint(
            x: point.x - windowFrame.minX,
            y: point.y - windowFrame.minY
        )
        let groupID = Int64(DispatchTime.now().uptimeNanoseconds & UInt64(Int64.max))
        for step in computerUseChromiumClickPlan(
            point: point,
            windowPoint: windowPoint,
            count: count
        ) {
            let type: CGEventType
            switch step.kind {
            case .move: type = .mouseMoved
            case .down: type = .leftMouseDown
            case .up: type = .leftMouseUp
            }
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: step.point,
                mouseButton: .left
            ) else { throw BridgeError("Unable to create Chromium mouse event") }
            configureTargetedMouseEvent(
                event,
                point: step.point,
                button: .left,
                clickState: Int(step.clickState),
                windowID: windowID,
                windowFrame: windowFrame,
                pid: pid,
                groupID: groupID,
                phase: step.phase,
                windowPoint: step.windowPoint
            )
            SkyLightEventBridge.shared.post(event, to: pid)
            if step.delayAfterMilliseconds > 0 {
                usleep(step.delayAfterMilliseconds * 1_000)
            }
        }
        return SkyLightEventBridge.shared.supportsTargetedPost
            ? "skylight_chromium"
            : "cgevent_chromium_fallback"
    }

    private func withAppFronted<T>(
        app: NSRunningApplication,
        window: AXUIElement,
        windowID: CGWindowID?,
        operation: () throws -> T
    ) throws -> T {
        let previous = NSWorkspace.shared.frontmostApplication
        let shouldRestore = previous?.processIdentifier != app.processIdentifier
        defer {
            if shouldRestore, let previous, !previous.isTerminated {
                Thread.sleep(forTimeInterval: 0.12)
                _ = previous.activate(options: [.activateAllWindows])
            }
        }
        _ = app.activate(options: [.activateAllWindows])
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        for _ in 0..<8 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier,
           let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let opened = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                opened.signal()
            }
            _ = opened.wait(timeout: .now() + 2)
            for _ in 0..<8 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw BridgeError("Unable to bring the target app forward for foreground delivery")
        }
        if let windowID {
            for _ in 0..<12 where !windowIsOnVisibleSpace(windowID) {
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard windowIsOnVisibleSpace(windowID) else {
                throw BridgeError(
                    "The target window is on another Space and macOS did not bring that Space forward"
                )
            }
        }
        return try operation()
    }

    private func drag(from: CGPoint, to: CGPoint, pid: pid_t, global: Bool = false) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw BridgeError("Unable to create targeted drag event source")
        }
        try postMouseEvent(type: .mouseMoved, source: source, point: from, button: .left, pid: pid, global: global)
        try postMouseEvent(type: .leftMouseDown, source: source, point: from, button: .left, pid: pid, global: global)
        for step in 1...10 {
            let progress = CGFloat(step) / 10
            try postMouseEvent(
                type: .leftMouseDragged,
                source: source,
                point: CGPoint(
                    x: from.x + (to.x - from.x) * progress,
                    y: from.y + (to.y - from.y) * progress
                ),
                button: .left,
                pid: pid,
                global: global
            )
        }
        try postMouseEvent(type: .leftMouseUp, source: source, point: to, button: .left, pid: pid, global: global)
    }

    private func postMouseEvent(
        type: CGEventType,
        source: CGEventSource,
        point: CGPoint,
        button: CGMouseButton,
        pid: pid_t,
        global: Bool
    ) throws {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { throw BridgeError("Unable to create mouse event") }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        if global { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
        Thread.sleep(forTimeInterval: 0.02)
    }

    private func scroll(
        at point: CGPoint,
        direction: String,
        pages: Double,
        pid: pid_t,
        global: Bool = false
    ) throws {
        let magnitude = Int32(min(Double(Int32.max), max(1, (12 * pages).rounded())))
        let vertical: Int32 = direction == "up" ? magnitude : direction == "down" ? -magnitude : 0
        let horizontal: Int32 = direction == "left" ? magnitude : direction == "right" ? -magnitude : 0
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else { throw BridgeError("Unable to create scroll event") }
        event.location = point
        if global { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
    }

    private func keyPress(_ value: String, pid: pid_t, global: Bool = false) throws {
        let names: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
            "backspace": 51, "forwarddelete": 117, "home": 115, "end": 119,
            "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
            "pageup": 116, "pagedown": 121
        ]
        let parts = value.split(separator: "+").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let rawKey = parts.last, !rawKey.isEmpty else {
            throw BridgeError("Unsupported key: \(value)")
        }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            guard let flag = computerUseModifierFlag(named: modifier) else {
                throw BridgeError("Unsupported key modifier: \(modifier)")
            }
            flags.insert(flag)
        }
        if rawKey.count == 1, rawKey.uppercased() == rawKey, rawKey.lowercased() != rawKey {
            flags.insert(.maskShift)
        }
        let normalized = rawKey.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard let code = names[normalized] ?? names[rawKey.lowercased()] else {
            if flags.isEmpty, rawKey.count == 1 {
                return try typeText(rawKey, pid: pid, global: global)
            }
            throw BridgeError("Unsupported key: \(value)")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else { throw BridgeError("Unable to create keyboard event") }
        down.flags = flags
        up.flags = flags
        postKeyboardEvent(down, pid: pid, global: global)
        postKeyboardEvent(up, pid: pid, global: global)
    }

    private func typeText(_ text: String, pid: pid_t, global: Bool = false) throws {
        for character in text {
            if character == "\n" || character == "\r" {
                try postKeyCode(36, pid: pid, global: global)
                continue
            }
            if character == "\t" {
                try postKeyCode(48, pid: pid, global: global)
                continue
            }
            if character == "\u{8}" || character == "\u{7f}" {
                try postKeyCode(51, pid: pid, global: global)
                continue
            }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { throw BridgeError("Unable to create keyboard event") }
            let units = Array(String(character).utf16)
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
            postKeyboardEvent(down, pid: pid, global: global)
            postKeyboardEvent(up, pid: pid, global: global)
        }
    }

    private func postKeyCode(_ code: CGKeyCode, pid: pid_t, global: Bool) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else { throw BridgeError("Unable to create keyboard event") }
        postKeyboardEvent(down, pid: pid, global: global)
        postKeyboardEvent(up, pid: pid, global: global)
    }

    private func postKeyboardEvent(_ event: CGEvent, pid: pid_t, global: Bool) {
        if global { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
    }

    private func screenshot(
        windowID: CGWindowID?,
        fallbackFrame: CGRect?
    ) -> ScreenshotCapture? {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { return nil }
        guard let windowID else {
            return fallbackFrame.flatMap { screenshotRegion(frame: $0) }
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ScreenshotBox()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
            content, _ in
            guard let window = content?.windows.first(where: { $0.windowID == windowID }) else {
                semaphore.signal()
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let capturedWindowFrame = window.frame
            let scale = max(1, CGFloat(filter.pointPixelScale))
            configuration.width = max(2, Int((capturedWindowFrame.width * scale).rounded()))
            configuration.height = max(2, Int((capturedWindowFrame.height * scale).rounded()))
            configuration.scalesToFit = true
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, _ in
                if let image,
                   let data = NSBitmapImageRep(cgImage: image).representation(
                       using: .png,
                       properties: [:]
                   ) {
                    box.capture = ScreenshotCapture(
                        data: data,
                        pixelSize: CGSize(width: image.width, height: image.height),
                        windowFrame: capturedWindowFrame
                    )
                }
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 10)
        if let capture = box.capture { return capture }
        // A region fallback is valid only when the target is on the current
        // Space. Otherwise it would return pixels belonging to whichever
        // unrelated window happens to occupy the same coordinates.
        guard windowIsOnVisibleSpace(windowID) else { return nil }
        return fallbackFrame.flatMap { screenshotRegion(frame: $0) }
    }

    private func screenshotRegion(frame: CGRect) -> ScreenshotCapture? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ScreenshotBox()
        SCScreenshotManager.captureImage(in: frame) { image, _ in
            if let image,
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                box.capture = ScreenshotCapture(
                    data: data,
                    pixelSize: CGSize(width: image.width, height: image.height),
                    windowFrame: frame
                )
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return box.capture
    }

    private func windowIsOnVisibleSpace(_ windowID: CGWindowID) -> Bool {
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return computerUseWindowIsOnVisibleSpace(windowID, windowInfo: info)
    }

    private func requireAccessibility(prompt: Bool) throws {
        if AXIsProcessTrusted() { return }
        if prompt {
            _ = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            )
        }
        throw BridgeError("Enable Codevisor in System Settings → Privacy & Security → Accessibility")
    }
}

func computerUseScreenshotPoint(
    x: Double,
    y: Double,
    screenshotPixelSize: CGSize?,
    windowFrame: CGRect
) -> CGPoint {
    let xScale = screenshotPixelSize.map { windowFrame.width / max($0.width, 1) } ?? 1
    let yScale = screenshotPixelSize.map { windowFrame.height / max($0.height, 1) } ?? 1
    return CGPoint(
        x: min(
            windowFrame.maxX - 0.5,
            max(windowFrame.minX + 0.5, windowFrame.minX + x * xScale)
        ),
        y: min(
            windowFrame.maxY - 0.5,
            max(windowFrame.minY + 0.5, windowFrame.minY + y * yScale)
        )
    )
}

func computerUseScreenshotFrame(
    screenFrame: CGRect,
    screenshotPixelSize: CGSize?,
    windowFrame: CGRect?
) -> CGRect? {
    guard let windowFrame else { return nil }
    let xScale = screenshotPixelSize.map { max($0.width, 1) / max(windowFrame.width, 1) } ?? 1
    let yScale = screenshotPixelSize.map { max($0.height, 1) / max(windowFrame.height, 1) } ?? 1
    return CGRect(
        x: (screenFrame.minX - windowFrame.minX) * xScale,
        y: (screenFrame.minY - windowFrame.minY) * yScale,
        width: screenFrame.width * xScale,
        height: screenFrame.height * yScale
    )
}

private final class ScreenshotBox: @unchecked Sendable {
    var capture: ComputerUseBridge.ScreenshotCapture?
}
private struct BridgeError: LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}

private func writeAll(_ descriptor: Int32, _ data: Data) {
    data.withUnsafeBytes { bytes in
        guard var address = bytes.baseAddress else { return }
        var remaining = bytes.count
        while remaining > 0 {
            let count = Darwin.write(descriptor, address, remaining)
            if count <= 0 { return }
            remaining -= count
            address = address.advanced(by: count)
        }
    }
}

private func textResult(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]]]
}

private func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}

private func int(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
}

private func double(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
}

private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    copyAttribute(element, name) as? String
}

private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    copyAttribute(element, name) as! AXUIElement?
}

private func elementsAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    copyAttribute(element, name) as? [AXUIElement] ?? []
}

private func frame(of element: AXUIElement) -> CGRect? {
    guard let positionValue = copyAttribute(element, kAXPositionAttribute),
          let sizeValue = copyAttribute(element, kAXSizeAttribute),
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    let position = positionValue as! AXValue
    let size = sizeValue as! AXValue
    var origin = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions)
    else { return nil }
    return CGRect(origin: origin, size: dimensions)
}

private func frameObject(_ frame: CGRect) -> [String: Double] {
    ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try operation()
    }
}
