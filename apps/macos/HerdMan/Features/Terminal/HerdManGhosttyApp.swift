//  HerdManGhosttyApp: the process-wide libghostty runtime host.
//
//  Replaces the role of upstream Ghostty's `Ghostty.App` (references/ghostty/
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
    /// Flipped at the end of init; applyTheme only reloads a runtime that exists.
    private static var runtimeInitialized = false

    /// Applies a theme (nil = system look): stores it for a not-yet-created
    /// runtime, or rebuilds the live config and pushes it to the app and all
    /// open surfaces.
    static func applyTheme(_ theme: TerminalPalette?) {
        guard theme != currentTheme else { return }
        currentTheme = theme
        guard runtimeInitialized else { return }
        shared.reloadConfig()
    }

    // MARK: - Init

    private init() {
        // Point libghostty at the bundled resources (xterm-ghostty terminfo +
        // shell integration). Must be set BEFORE ghostty_init, which captures it.
        setenv("GHOSTTY_RESOURCES_DIR", Self.prepareBundledResources(), 1)

        _ = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

        let config = Ghostty.Config(config: Self.buildConfig(theme: Self.currentTheme))
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
    private static func buildConfig(theme: TerminalPalette?) -> ghostty_config_t {
        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)
        if let overrideFile = writeOverrideConfig(theme: theme) {
            ghostty_config_load_file(cfg, overrideFile)
        }
        ghostty_config_finalize(cfg)
        guard let cfg else { fatalError("ghostty_config_new returned nil.") }
        return cfg
    }

    /// Rebuilds the config for the current theme and pushes it to the app and
    /// every live surface.
    private func reloadConfig() {
        let newConfig = Ghostty.Config(config: Self.buildConfig(theme: Self.currentTheme))
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
              fm.fileExists(atPath: tarball.path),
              let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else {
            fatalError("Missing bundled ghostty-resources.tar.gz.")
        }

        let base = support
            .appendingPathComponent(HerdManAppVariant.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("ghostty-resources", isDirectory: true)
        let ghosttyDir = base.appendingPathComponent("ghostty", isDirectory: true)
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
            return ghosttyDir.path
        } catch {
            fatalError("Failed to prepare Ghostty resources: \(error).")
        }
    }

    /// Writes a tiny config file with our font + color overrides, and returns
    /// its path. With no theme, only the background is overridden; with a theme,
    /// the terminal takes the theme's full palette.
    private static func writeOverrideConfig(theme: TerminalPalette?) -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("herdman-ghostty.conf")
        var contents = "font-family = Menlo\n"
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
        } else if let background = resolvedBackgroundHex() {
            contents += "background = \(background)\n"
        }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }

    /// The app's dark window background as a `RRGGBB` hex string.
    private static func resolvedBackgroundHex() -> String? {
        let resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
        guard let rgb = resolved else { return "1E1E1E" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
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

    // MARK: - Runtime callbacks (bodies from upstream Ghostty.App L325-442)

    nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        let host = hostApp(from: userdata)
        // Wakeup can be called from any thread; tick on main.
        DispatchQueue.main.async { host.appTick() }
    }

    nonisolated static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        MainActor.assumeIsolated {
            let surface = surfaceUserdata(from: userdata)
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
        MainActor.assumeIsolated {
            let surfaceView = surfaceUserdata(from: userdata)
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
        MainActor.assumeIsolated {
            let surfaceView = surfaceUserdata(from: userdata)
            guard let surface = surfaceView.surface else { return }
            guard let string, let valueStr = String(cString: string, encoding: .utf8) else { return }
            guard let request = Ghostty.ClipboardRequest.from(request: request) else { return }

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
        MainActor.assumeIsolated {
            _ = surfaceUserdata(from: userdata)
            guard let pasteboard = NSPasteboard.ghostty(location) else { return }
            guard let content, len > 0 else { return }

            // Convert the C array to Swift array
            let contentArray = (0..<len).compactMap { i in
                Ghostty.ClipboardContent.from(content: content[i])
            }
            guard !contentArray.isEmpty else { return }

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

    nonisolated static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        MainActor.assumeIsolated {
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
                surfaceView.setTitle(title)

            case GHOSTTY_ACTION_PWD:
                guard let surfaceView = surfaceView(for: target) else { return false }
                guard let pwd = String(cString: action.action.pwd.pwd!, encoding: .utf8) else { return false }
                surfaceView.pwd = pwd

            case GHOSTTY_ACTION_MOUSE_SHAPE:
                guard let surfaceView = surfaceView(for: target) else { return false }
                surfaceView.setCursorShape(action.action.mouse_shape)

            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                guard let surfaceView = surfaceView(for: target) else { return false }
                switch action.action.mouse_visibility {
                case GHOSTTY_MOUSE_VISIBLE: surfaceView.setCursorVisibility(true)
                case GHOSTTY_MOUSE_HIDDEN: surfaceView.setCursorVisibility(false)
                default: return false
                }

            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                guard let surfaceView = surfaceView(for: target) else { return false }
                let v = action.action.mouse_over_link
                guard v.len > 0 else {
                    surfaceView.hoverUrl = nil
                    break
                }
                let buffer = Data(bytes: v.url!, count: v.len)
                surfaceView.hoverUrl = String(data: buffer, encoding: .utf8)

            case GHOSTTY_ACTION_INITIAL_SIZE:
                guard let surfaceView = surfaceView(for: target) else { return false }
                let v = action.action.initial_size
                surfaceView.initialSize = NSSize(width: Double(v.width), height: Double(v.height))

            case GHOSTTY_ACTION_CELL_SIZE:
                guard let surfaceView = surfaceView(for: target) else { return false }
                let v = action.action.cell_size
                let backingSize = NSSize(width: Double(v.width), height: Double(v.height))
                DispatchQueue.main.async { [weak surfaceView] in
                    guard let surfaceView else { return }
                    surfaceView.cellSize = surfaceView.convertFromBacking(backingSize)
                }

            case GHOSTTY_ACTION_RENDERER_HEALTH:
                guard let surfaceView = surfaceView(for: target) else { return false }
                NotificationCenter.default.post(
                    name: Ghostty.Notification.didUpdateRendererHealth,
                    object: surfaceView,
                    userInfo: ["health": action.action.renderer_health]
                )

            case GHOSTTY_ACTION_KEY_SEQUENCE:
                guard let surfaceView = surfaceView(for: target) else { return false }
                let v = action.action.key_sequence
                if v.active {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.didContinueKeySequence,
                        object: surfaceView,
                        userInfo: [Ghostty.Notification.KeySequenceKey: Ghostty.keyboardShortcut(for: v.trigger) as Any]
                    )
                } else {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.didEndKeySequence,
                        object: surfaceView
                    )
                }

            case GHOSTTY_ACTION_KEY_TABLE:
                guard let surfaceView = surfaceView(for: target) else { return false }
                guard let keyTable = Ghostty.Action.KeyTable(c: action.action.key_table) else { return false }
                NotificationCenter.default.post(
                    name: Ghostty.Notification.didChangeKeyTable,
                    object: surfaceView,
                    userInfo: [Ghostty.Notification.KeyTableKey: keyTable]
                )

            case GHOSTTY_ACTION_CONFIG_CHANGE:
                // Clone the config so we own the memory (upstream L2194-2240).
                let config = Ghostty.Config(clone: action.action.config_change.config)
                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: nil,
                        userInfo: [SwiftUI.Notification.Name.GhosttyConfigChangeKey: config]
                    )
                    hostApp(from: ghostty_app_userdata(app)).config = config
                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface,
                          let surfaceView = surfaceView(from: surface) else { return false }
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: surfaceView,
                        userInfo: [SwiftUI.Notification.Name.GhosttyConfigChangeKey: config]
                    )
                default:
                    return false
                }

            case GHOSTTY_ACTION_RELOAD_CONFIG:
                // Rebuild our themed config (HerdMan has no on-disk user config flow).
                hostApp(from: ghostty_app_userdata(app)).reloadConfig()

            case GHOSTTY_ACTION_COLOR_CHANGE:
                guard let surfaceView = surfaceView(for: target) else { return false }
                NotificationCenter.default.post(
                    name: .ghosttyColorDidChange,
                    object: surfaceView,
                    userInfo: [SwiftUI.Notification.Name.GhosttyColorChangeKey: Ghostty.Action.ColorChange(c: action.action.color_change)]
                )

            case GHOSTTY_ACTION_RING_BELL:
                guard let surfaceView = surfaceView(for: target) else { return false }
                NotificationCenter.default.post(name: .ghosttyBellDidRing, object: surfaceView)

            case GHOSTTY_ACTION_SELECTION_CHANGED:
                guard let surfaceView = surfaceView(for: target) else { return false }
                NotificationCenter.default.post(name: .ghosttySelectionDidChange, object: surfaceView)

            case GHOSTTY_ACTION_READONLY:
                guard let surfaceView = surfaceView(for: target) else { return false }
                NotificationCenter.default.post(
                    name: .ghosttyDidChangeReadonly,
                    object: surfaceView,
                    userInfo: [SwiftUI.Notification.Name.ReadonlyKey: action.action.readonly == GHOSTTY_READONLY_ON]
                )

            case GHOSTTY_ACTION_PROGRESS_REPORT:
                guard let surfaceView = surfaceView(for: target) else { return false }
                let host = hostApp(from: ghostty_app_userdata(app))
                guard host.config.progressStyle else {
                    DispatchQueue.main.async { surfaceView.progressReport = nil }
                    break
                }
                let progressReport = Ghostty.Action.ProgressReport(c: action.action.progress_report)
                DispatchQueue.main.async {
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
                guard host.config.autoSecureInput else { break }
                switch mode {
                case .on: surfaceView.passwordInput = true
                case .off: surfaceView.passwordInput = false
                case .toggle: surfaceView.passwordInput = !surfaceView.passwordInput
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
    }

    /// Resolves the surface view for a surface-targeted action.
    nonisolated private static func surfaceView(for target: ghostty_target_s) -> Ghostty.SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        guard let surface = target.target.surface else { return nil }
        return surfaceView(from: surface)
    }
}
