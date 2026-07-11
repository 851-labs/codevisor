//  HerdManGhosttyApp: the process-wide libghostty runtime host.
//
//  Replaces the role of upstream Ghostty's `Ghostty.App` (.repos/ghostty/
//  macos/Sources/Ghostty/Ghostty.App.swift) for HerdMan's embedding: it owns the
//  single `ghostty_app_t`, registers the runtime callbacks (clipboard, wakeup,
//  action dispatch), and manages HerdMan's theme-driven config. Callback and
//  action-handler bodies are copied from upstream near-verbatim; the action
//  switch only implements per-surface actions HerdMan supports — window/tab/
//  split/app-management actions return false (unhandled).

import AppKit
import Foundation
import GhosttyKit
import HerdManCore
import HerdManTheming
import SwiftUI
import os

@MainActor
final class HerdManGhosttyApp {
    static let shared = HerdManGhosttyApp()

    private static let ghosttyDefaultFontSize: Float = 13
    private static let terminalFontScale: Float = 0.9
    private static var terminalFontSize: Float {
        ghosttyDefaultFontSize * terminalFontScale
    }

    /// The single ghostty app instance shared by all surfaces. Implicitly
    /// unwrapped because `self` must be passed as the runtime-config userdata
    /// before `ghostty_app_new` can run (same reason upstream's App.app is
    /// optional); it is non-nil for the object's entire visible lifetime.
    private(set) var app: ghostty_app_t!

    /// The app-wide config. Replaced on theme changes and CONFIG_CHANGE actions.
    /// Vendored `Ghostty.SurfaceView` reads this at init for its DerivedConfig.
    private(set) var config: Ghostty.Config

    /// Live surface views that receive config updates on theme switches.
    private let surfaces = NSHashTable<Ghostty.SurfaceView>.weakObjects()

    // MARK: - Theme

    /// The active terminal theme. Seeded by ThemedRoot before `prewarm()` runs
    /// (so the first config is already themed) and updated on theme switches.
    /// Static so setting it never instantiates the runtime.
    private static var currentTheme: TerminalPalette?
    /// The resolved app appearance. This matters when `currentTheme` is nil:
    /// both system theme slots use nil palettes, but Ghostty still needs a
    /// config reload when the system moves between light and dark.
    private static var currentSystemIsDark: Bool?
    /// Flipped at the end of init; applyTheme only reloads a runtime that exists.
    private static var runtimeInitialized = false

    /// Applies a theme (nil = system look): stores it for a not-yet-created
    /// runtime, or rebuilds the live config and pushes it to the app and all
    /// open surfaces.
    static func applyTheme(_ theme: TerminalPalette?, systemIsDark: Bool) {
        let themeChanged = theme != currentTheme
        let systemAppearanceChanged = theme == nil && currentSystemIsDark != systemIsDark
        currentTheme = theme
        currentSystemIsDark = systemIsDark
        guard themeChanged || systemAppearanceChanged else { return }
        guard runtimeInitialized else { return }
        shared.reloadConfig()
    }

    // MARK: - Init

    private init() {
        // Point libghostty at the bundled resources (xterm-ghostty terminfo +
        // shell integration). Must be set BEFORE ghostty_init, which captures it.
        setenv("GHOSTTY_RESOURCES_DIR", Self.prepareBundledResources(), 1)

        _ = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

        let config = Ghostty.Config(config: Self.buildConfig(
            theme: Self.currentTheme,
            systemIsDark: Self.currentSystemIsDark
        ))
        self.config = config

        // Runtime config modeled on upstream Ghostty.App.init (L60-70). The
        // userdata is this host; callbacks resolve it via ghostty_app_userdata,
        // never via `shared` (wakeup can fire while the `shared` static-let is
        // still initializing, and re-entering that dispatch_once traps).
        var runtime_cfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in HerdManGhosttyApp.wakeup(userdata) },
            action_cb: { app, target, action in HerdManGhosttyApp.action(app!, target: target, action: action) },
            read_clipboard_cb: { userdata, loc, state in HerdManGhosttyApp.readClipboard(userdata, location: loc, state: state) },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                HerdManGhosttyApp.confirmReadClipboard(userdata, string: str, state: state, request: request) },
            write_clipboard_cb: { userdata, loc, content, len, confirm in
                HerdManGhosttyApp.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm) },
            close_surface_cb: { userdata, processAlive in HerdManGhosttyApp.closeSurface(userdata, processAlive: processAlive) }
        )

        guard let app = ghostty_app_new(&runtime_cfg, config.config) else {
            fatalError("ghostty_app_new returned nil.")
        }
        self.app = app

        ghostty_app_set_focus(app, NSApp.isActive)

        // App-level observers (upstream Ghostty.App.init L84-99). The keyboard
        // one is required for correct input after keyboard-layout changes.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(keyboardSelectionDidChange(notification:)),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(notification:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(applicationDidResignActive(notification:)),
            name: NSApplication.didResignActiveNotification,
            object: nil)

        ghostty_app_keyboard_changed(app)

        Self.runtimeInitialized = true
    }

    // MARK: - Surface registry

    func register(_ view: Ghostty.SurfaceView) {
        surfaces.add(view)
    }

    func unregister(_ view: Ghostty.SurfaceView) {
        surfaces.remove(view)
    }

    // MARK: - App operations

    func appTick() {
        ghostty_app_tick(app)
    }

    @objc private func keyboardSelectionDidChange(notification: NSNotification) {
        ghostty_app_keyboard_changed(app)
    }

    @objc private func applicationDidBecomeActive(notification: NSNotification) {
        ghostty_app_set_focus(app, true)
    }

    @objc private func applicationDidResignActive(notification: NSNotification) {
        ghostty_app_set_focus(app, false)
    }

    // MARK: - Config building (migrated from the previous GhosttyRuntime bridge)

    /// Builds a finalized raw config: default files + our override file (font,
    /// background, and — when themed — the full terminal palette).
    private static func buildConfig(
        theme: TerminalPalette?,
        systemIsDark: Bool?
    ) -> ghostty_config_t {
        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)
        if let overrideFile = writeOverrideConfig(theme: theme, systemIsDark: systemIsDark) {
            ghostty_config_load_file(cfg, overrideFile)
        }
        ghostty_config_finalize(cfg)
        guard let cfg else { fatalError("ghostty_config_new returned nil.") }
        return cfg
    }

    /// Rebuilds the config for the current theme and pushes it to the app and
    /// every live surface.
    private func reloadConfig() {
        let newConfig = Ghostty.Config(config: Self.buildConfig(
            theme: Self.currentTheme,
            systemIsDark: Self.currentSystemIsDark
        ))
        ghostty_app_update_config(app, newConfig.config!)
        for view in surfaces.allObjects {
            if let surface = view.surface {
                ghostty_surface_update_config(surface, newConfig.config!)
            }
        }
        // The old Ghostty.Config frees its ghostty_config_t in deinit.
        config = newConfig
    }

    /// Extracts the bundled Ghostty resources (terminfo + shell integration)
    /// into Application Support and returns the path to use as
    /// `GHOSTTY_RESOURCES_DIR` — the `ghostty` subdir, with `terminfo` adjacent
    /// as libghostty expects (it reads `dirname(resources)/terminfo`).
    private static func prepareBundledResources() -> String {
        let fm = FileManager.default
        guard let tarball = Bundle.main.url(forResource: "ghostty-resources", withExtension: "tar.gz")
            ?? Bundle.main.resourceURL?.appendingPathComponent("ghostty-resources.tar.gz"),
              fm.fileExists(atPath: tarball.path)
        else {
            fatalError("Missing bundled ghostty-resources.tar.gz.")
        }

        let base = HerdManAppVariant.applicationSupportURL(fileManager: fm)
            .appendingPathComponent("ghostty-resources", isDirectory: true)
        let ghosttyDir = base.appendingPathComponent("ghostty", isDirectory: true)

        // Extraction runs synchronously before ghostty_init (which captures
        // GHOSTTY_RESOURCES_DIR), so it can't move off the launch path — but
        // it CAN be skipped: a version stamp keyed on the app build and the
        // tarball's size/mtime makes the tar spawn a once-per-update cost
        // instead of a synchronous main-thread process on every launch.
        let stampURL = base.appendingPathComponent(".extracted-stamp")
        let attributes = try? fm.attributesOfItem(atPath: tarball.path)
        let tarballSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let tarballMtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let stamp = "\(bundleVersion)|\(tarballSize)|\(tarballMtime)"
        if fm.fileExists(atPath: ghosttyDir.path),
           let existing = try? String(contentsOf: stampURL, encoding: .utf8),
           existing == stamp {
            return ghosttyDir.path
        }

        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", tarball.path, "-C", base.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0, fm.fileExists(atPath: ghosttyDir.path) else {
                fatalError("Failed to extract Ghostty resources from \(tarball.path).")
            }
            try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
            return ghosttyDir.path
        } catch {
            fatalError("Failed to prepare Ghostty resources: \(error).")
        }
    }

    /// Writes a tiny config file with our font + color overrides, and returns
    /// its path. With no theme, the terminal follows the system light/dark
    /// appearance; with a theme, it takes the theme's full palette.
    private static func writeOverrideConfig(
        theme: TerminalPalette?,
        systemIsDark: Bool?
    ) -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("herdman-ghostty.conf")
        var contents = """
        font-family = Menlo
        font-size = \(terminalFontSize)

        """
        if let theme {
            contents += "background = \(theme.background.hexString())\n"
            contents += "foreground = \(theme.foreground.hexString())\n"
            if let cursor = theme.cursorColor {
                contents += "cursor-color = \(cursor.hexString())\n"
            }
            if let selectionBg = theme.selectionBackground {
                contents += "selection-background = \(selectionBg.hexString())\n"
            }
            if let selectionFg = theme.selectionForeground {
                contents += "selection-foreground = \(selectionFg.hexString())\n"
            }
            // ANSI 0-15; slots the theme doesn't define keep Ghostty defaults.
            for (index, color) in theme.ansi.enumerated() {
                if let color {
                    contents += "palette = \(index)=\(color.hexString())\n"
                }
            }
        } else {
            let isDark = systemIsDark
                ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let background = isDark ? "1E1E1E" : "FFFFFF"
            let foreground = isDark ? "FFFFFF" : "000000"
            contents += "background = \(background)\n"
            contents += "foreground = \(foreground)\n"
            contents += "cursor-color = \(foreground)\n"
        }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }

    // MARK: - Userdata resolution (upstream Ghostty.App L461-477)

    nonisolated private static func hostApp(from userdata: UnsafeMutableRawPointer?) -> HerdManGhosttyApp {
        Unmanaged<HerdManGhosttyApp>.fromOpaque(userdata!).takeUnretainedValue()
    }

    nonisolated private static func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> Ghostty.SurfaceView {
        Unmanaged<Ghostty.SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
    }

    nonisolated private static func surfaceView(from surface: ghostty_surface_t) -> Ghostty.SurfaceView? {
        guard let surface_ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<Ghostty.SurfaceView>.fromOpaque(surface_ud).takeUnretainedValue()
    }

    /// Runs UI work on the main actor from a libghostty callback: immediately
    /// when the callback arrived on the main thread (the common case — the
    /// app loop ticks on main), or dispatched when it arrived on another
    /// thread (the renderer fires cell-size/progress actions during a live
    /// resize; upstream Ghostty.App hops these via DispatchQueue.main).
    ///
    /// This replaces blanket `MainActor.assumeIsolated`, which TRAPS on any
    /// off-main callback. Callers must extract all C-pointer payloads
    /// (strings, buffers, config) BEFORE calling — the pointers do not
    /// outlive the callback.
    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Runtime callbacks (bodies from upstream Ghostty.App L325-442)

    nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        let host = hostApp(from: userdata)
        // Wakeup can be called from any thread; tick on main.
        DispatchQueue.main.async { host.appTick() }
    }

    nonisolated static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        let surface = surfaceUserdata(from: userdata)
        onMain {
            NotificationCenter.default.post(name: Ghostty.Notification.ghosttyCloseSurface, object: surface, userInfo: [
                "process_alive": processAlive,
            ])
        }
    }

    nonisolated static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        let surfaceView = surfaceUserdata(from: userdata)

        // The synchronous Bool (did we handle it?) needs the pasteboard,
        // which is main-thread territory. Reads originate from input
        // processing on main in practice; an off-main caller gets the
        // completion dispatched and an optimistic `true` (worst case a
        // paste binding consumes on an empty clipboard) instead of the
        // hard trap `assumeIsolated` used to be.
        guard Thread.isMainThread else {
            onMain {
                guard let surface = surfaceView.surface else { return }
                guard let pasteboard = NSPasteboard.ghostty(location) else { return }
                guard let str = pasteboard.getOpinionatedStringContents() else { return }
                completeClipboardRequest(surface, data: str, state: state)
            }
            return true
        }

        return MainActor.assumeIsolated {
            guard let surface = surfaceView.surface else { return false }

            // Get our pasteboard
            guard let pasteboard = NSPasteboard.ghostty(location) else { return false }

            // Return false if there is no text-like clipboard content so
            // performable paste bindings can pass through to the terminal.
            guard let str = pasteboard.getOpinionatedStringContents() else { return false }

            completeClipboardRequest(surface, data: str, state: state)
            return true
        }
    }

    /// HERDMAN NOTE: upstream posts a notification consumed by a dedicated
    /// ClipboardConfirmation window controller. HerdMan shows a plain NSAlert,
    /// preserving the paste-protection semantics in far less code.
    nonisolated static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        let surfaceView = surfaceUserdata(from: userdata)
        // Copy the C string before hopping — the pointer dies with the callback.
        guard let string, let valueStr = String(cString: string, encoding: .utf8) else { return }
        guard let request = Ghostty.ClipboardRequest.from(request: request) else { return }

        onMain {
            guard let surface = surfaceView.surface else { return }

            let alert = NSAlert()
            switch request {
            case .paste:
                alert.messageText = "Warning: Potentially Unsafe Paste"
                alert.informativeText = "Pasting this text may be dangerous as it looks like some text will be executed as a command."
            case .osc_52_read:
                alert.messageText = "Authorize Clipboard Access"
                alert.informativeText = "An application is attempting to read from the clipboard."
            case .osc_52_write:
                alert.messageText = "Authorize Clipboard Access"
                alert.informativeText = "An application is attempting to write to the clipboard."
            }
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")

            let confirmed = alert.runModal() == .alertFirstButtonReturn
            completeClipboardRequest(surface, data: confirmed ? valueStr : "", state: state, confirmed: true)
        }
    }

    static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        data: String,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        data.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
        }
    }

    nonisolated static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        _ = surfaceUserdata(from: userdata)
        guard let content, len > 0 else { return }

        // Convert the C array to a Swift array BEFORE hopping to main —
        // the content pointers die with the callback.
        let contentArray = (0..<len).compactMap { i in
            Ghostty.ClipboardContent.from(content: content[i])
        }
        guard !contentArray.isEmpty else { return }

        onMain {
            guard let pasteboard = NSPasteboard.ghostty(location) else { return }

            if !confirm {
                // Declare all types
                let types = contentArray.compactMap { item in
                    NSPasteboard.PasteboardType(mimeType: item.mime)
                }
                pasteboard.declareTypes(types, owner: nil)

                // Set data for each type
                for item in contentArray {
                    guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
                    pasteboard.setString(item.data, forType: type)
                }
                return
            }

            // OSC 52 write confirmation via a plain alert (see confirmReadClipboard note).
            guard let textPlainContent = contentArray.first(where: { $0.mime == "text/plain" }) else { return }
            let alert = NSAlert()
            alert.messageText = "Authorize Clipboard Access"
            alert.informativeText = "An application is attempting to write to the clipboard:\n\n\(textPlainContent.data.prefix(256))"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(textPlainContent.data, forType: .string)
            }
        }
    }

    // MARK: - Action dispatch (subset of upstream Ghostty.App.action L481-685)

    /// Runs a libghostty action. NOT main-isolated: while most actions arrive
    /// on the main thread (the app loop ticks there), the renderer thread
    /// fires cell-size and progress-report actions during a live resize —
    /// upstream Ghostty deliberately leaves this handler unisolated and hops
    /// those to main. Each case therefore extracts its C payload
    /// synchronously (the pointers die with the callback) and applies UI
    /// state via `onMain`; the Bool (action supported?) is decided
    /// synchronously from the tag and payload validity.
    nonisolated static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_APP, GHOSTTY_TARGET_SURFACE:
            break
        default:
            Ghostty.logger.warning("unknown action target=\(target.tag.rawValue, privacy: .public)")
            return false
        }

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            guard let title = String(cString: action.action.set_title.title!, encoding: .utf8) else { return false }
            onMain { surfaceView.setTitle(title) }

        case GHOSTTY_ACTION_PWD:
            guard let surfaceView = surfaceView(for: target) else { return false }
            guard let pwd = String(cString: action.action.pwd.pwd!, encoding: .utf8) else { return false }
            onMain { surfaceView.pwd = pwd }

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let shape = action.action.mouse_shape
            onMain { surfaceView.setCursorShape(shape) }

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let visible: Bool
            switch action.action.mouse_visibility {
            case GHOSTTY_MOUSE_VISIBLE: visible = true
            case GHOSTTY_MOUSE_HIDDEN: visible = false
            default: return false
            }
            onMain { surfaceView.setCursorVisibility(visible) }

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let v = action.action.mouse_over_link
            let url: String?
            if v.len > 0 {
                url = String(data: Data(bytes: v.url!, count: v.len), encoding: .utf8)
            } else {
                url = nil
            }
            onMain { surfaceView.hoverUrl = url }

        case GHOSTTY_ACTION_INITIAL_SIZE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let v = action.action.initial_size
            let size = NSSize(width: Double(v.width), height: Double(v.height))
            onMain { surfaceView.initialSize = size }

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let v = action.action.cell_size
            let backingSize = NSSize(width: Double(v.width), height: Double(v.height))
            onMain { [weak surfaceView] in
                guard let surfaceView else { return }
                surfaceView.cellSize = surfaceView.convertFromBacking(backingSize)
            }

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let health = action.action.renderer_health
            onMain {
                NotificationCenter.default.post(
                    name: Ghostty.Notification.didUpdateRendererHealth,
                    object: surfaceView,
                    userInfo: ["health": health]
                )
            }

        case GHOSTTY_ACTION_KEY_SEQUENCE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let v = action.action.key_sequence
            if v.active {
                let shortcut = Ghostty.keyboardShortcut(for: v.trigger)
                onMain {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.didContinueKeySequence,
                        object: surfaceView,
                        userInfo: [Ghostty.Notification.KeySequenceKey: shortcut as Any]
                    )
                }
            } else {
                onMain {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.didEndKeySequence,
                        object: surfaceView
                    )
                }
            }

        case GHOSTTY_ACTION_KEY_TABLE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            guard let keyTable = Ghostty.Action.KeyTable(c: action.action.key_table) else { return false }
            onMain {
                NotificationCenter.default.post(
                    name: Ghostty.Notification.didChangeKeyTable,
                    object: surfaceView,
                    userInfo: [Ghostty.Notification.KeyTableKey: keyTable]
                )
            }

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // Clone the config so we own the memory (upstream L2194-2240) —
            // synchronously: the source pointer dies with the callback.
            let config = Ghostty.Config(clone: action.action.config_change.config)
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                let host = hostApp(from: ghostty_app_userdata(app))
                onMain {
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: nil,
                        userInfo: [SwiftUI.Notification.Name.GhosttyConfigChangeKey: config]
                    )
                    host.config = config
                }
            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface,
                      let surfaceView = surfaceView(from: surface) else { return false }
                onMain {
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: surfaceView,
                        userInfo: [SwiftUI.Notification.Name.GhosttyConfigChangeKey: config]
                    )
                }
            default:
                return false
            }

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // Rebuild our themed config (HerdMan has no on-disk user config flow).
            let host = hostApp(from: ghostty_app_userdata(app))
            onMain { host.reloadConfig() }

        case GHOSTTY_ACTION_COLOR_CHANGE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let change = Ghostty.Action.ColorChange(c: action.action.color_change)
            onMain {
                NotificationCenter.default.post(
                    name: .ghosttyColorDidChange,
                    object: surfaceView,
                    userInfo: [SwiftUI.Notification.Name.GhosttyColorChangeKey: change]
                )
            }

        case GHOSTTY_ACTION_RING_BELL:
            guard let surfaceView = surfaceView(for: target) else { return false }
            onMain {
                NotificationCenter.default.post(name: .ghosttyBellDidRing, object: surfaceView)
            }

        case GHOSTTY_ACTION_SELECTION_CHANGED:
            guard let surfaceView = surfaceView(for: target) else { return false }
            onMain {
                NotificationCenter.default.post(name: .ghosttySelectionDidChange, object: surfaceView)
            }

        case GHOSTTY_ACTION_READONLY:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let readonly = action.action.readonly == GHOSTTY_READONLY_ON
            onMain {
                NotificationCenter.default.post(
                    name: .ghosttyDidChangeReadonly,
                    object: surfaceView,
                    userInfo: [SwiftUI.Notification.Name.ReadonlyKey: readonly]
                )
            }

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let host = hostApp(from: ghostty_app_userdata(app))
            let progressReport = Ghostty.Action.ProgressReport(c: action.action.progress_report)
            onMain {
                guard host.config.progressStyle else {
                    surfaceView.progressReport = nil
                    return
                }
                if progressReport.state == .remove {
                    surfaceView.progressReport = nil
                } else {
                    surfaceView.progressReport = progressReport
                }
            }

        case GHOSTTY_ACTION_SECURE_INPUT:
            // Surface-scoped secure input only (upstream L1575-1607); the
            // app-target variant needs AppDelegate plumbing we don't have.
            guard let mode = Ghostty.SetSecureInput.from(action.action.secure_input) else { return false }
            guard let surfaceView = surfaceView(for: target) else { return false }
            let host = hostApp(from: ghostty_app_userdata(app))
            onMain {
                guard host.config.autoSecureInput else { return }
                switch mode {
                case .on: surfaceView.passwordInput = true
                case .off: surfaceView.passwordInput = false
                case .toggle: surfaceView.passwordInput = !surfaceView.passwordInput
                }
            }

        case GHOSTTY_ACTION_SIZE_LIMIT:
            // Accepted but nothing to do: HerdMan's panel controls sizing.
            break

        default:
            // Window/tab/split/app-management actions HerdMan does not
            // support (NEW_WINDOW, NEW_TAB, NEW_SPLIT, GOTO_*, TOGGLE_*,
            // INSPECTOR, QUIT, OPEN_*, UNDO/REDO, search UI, ...).
            return false
        }

        return true
    }

    /// Resolves the surface view for a surface-targeted action.
    nonisolated private static func surfaceView(for target: ghostty_target_s) -> Ghostty.SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        guard let surface = target.target.surface else { return nil }
        return surfaceView(from: surface)
    }
}
