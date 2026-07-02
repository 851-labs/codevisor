//  Terminal backend powered by libghostty.
//
//  GhosttyKit.xcframework is a required build input. Modeled on Ghostty's own
//  macOS SurfaceView (references/ghostty/macos/Sources/Ghostty, MIT-licensed). This is a focused
//  single-surface integration covering lifecycle, render, focus, resize, and
//  keyboard/mouse forwarding; for full IME/marked-text fidelity, vendor
//  Ghostty's SurfaceView_AppKit input layer.

import AppKit
import Foundation
import GhosttyKit
import HerdManCore
import HerdManTheming

/// Holds the global `ghostty_app_t` outside `GhosttyRuntime.shared` so the
/// `wakeup` callback can reach it WITHOUT touching the `shared` `static let`
/// (Swift backs `static let` with `dispatch_once`; libghostty may fire `wakeup`
/// while `shared` is still initializing, and re-entering that `once` traps with
/// `_dispatch_once_wait` / EXC_BREAKPOINT).
private nonisolated(unsafe) var gGhosttyApp: ghostty_app_t?

/// Process-wide libghostty runtime. Initializes the library and creates the
/// single `ghostty_app_t` that all surfaces share. Created lazily on first use.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    /// The active terminal theme. Seeded by ThemedRoot before `prewarm()`
    /// runs (so the first config is already themed) and updated on theme
    /// switches. Static so setting it never instantiates the runtime.
    private static var currentTheme: TerminalPalette?
    /// Flipped at the end of init; applyTheme only reloads a runtime that
    /// actually exists.
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

    var app: ghostty_app_t {
        guard let app = gGhosttyApp else {
            fatalError("Ghostty runtime did not create an app instance.")
        }
        return app
    }
    private var config: ghostty_config_t?
    /// Live surfaces that receive config updates on theme switches.
    private var liveSurfaces: [ObjectIdentifier: ghostty_surface_t] = [:]

    private init() {
        // Point libghostty at the bundled resources (xterm-ghostty terminfo +
        // shell integration) so the shell gets TERM=xterm-ghostty and shell
        // integration. Must be set BEFORE ghostty_init, which captures it.
        setenv("GHOSTTY_RESOURCES_DIR", Self.prepareBundledResources(), 1)

        _ = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

        let cfg = Self.buildConfig(theme: Self.currentTheme)
        config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyRuntime.wakeup() },
            action_cb: { _, _, _ in false },
            read_clipboard_cb: { _, _, _ in false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            close_surface_cb: { _, _ in }
        )
        // Publish the app pointer to the global BEFORE set_focus (which can
        // trigger a wakeup) so the callback always sees a valid app.
        gGhosttyApp = ghostty_app_new(&runtime, cfg)
        guard let app = gGhosttyApp else {
            fatalError("ghostty_app_new returned nil.")
        }
        ghostty_app_set_focus(app, true)
        Self.runtimeInitialized = true
    }

    // MARK: - Surface registry

    func register(_ surface: ghostty_surface_t, for view: GhosttySurfaceView) {
        liveSurfaces[ObjectIdentifier(view)] = surface
    }

    func unregister(_ view: GhosttySurfaceView) {
        liveSurfaces.removeValue(forKey: ObjectIdentifier(view))
    }

    // MARK: - Config

    /// Builds a finalized config: default files + our override file (font,
    /// background, and — when themed — the full terminal palette).
    private static func buildConfig(theme: TerminalPalette?) -> ghostty_config_t {
        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)
        // Override the font (a guaranteed-present system monospace so the
        // renderer always has a font) and the colors (theme palette, or the
        // app's window background so the terminal blends with the app).
        if let overrideFile = writeOverrideConfig(theme: theme) {
            ghostty_config_load_file(cfg, overrideFile)
        }
        ghostty_config_finalize(cfg)
        guard let cfg else { fatalError("ghostty_config_new returned nil.") }
        return cfg
    }

    /// Rebuilds the config for the current theme and pushes it to the app and
    /// every live surface. The old config is freed only after both update
    /// paths have taken the new one.
    private func reloadConfig() {
        let cfg = Self.buildConfig(theme: Self.currentTheme)
        if let app = gGhosttyApp { ghostty_app_update_config(app, cfg) }
        for surface in liveSurfaces.values { ghostty_surface_update_config(surface, cfg) }
        if let old = config { ghostty_config_free(old) }
        config = cfg
    }

    func tick() {
        if let app = gGhosttyApp { ghostty_app_tick(app) }
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
    /// its path. Returns nil on failure (config load is then skipped). With no
    /// theme, only the background is overridden (the app's window background);
    /// with a theme, the terminal takes the theme's full palette. All theme
    /// colors are opaque sRGB (composited upstream) since Ghostty hex carries
    /// no alpha.
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

    /// The app's dark window background as a `RRGGBB` hex string for Ghostty's
    /// `background` option, so the terminal blends with the app instead of being
    /// pure black. Falls back to a dark gray.
    private static func resolvedBackgroundHex() -> String? {
        let resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
        guard let rgb = resolved else { return "1E1E1E" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// Called by libghostty (any thread) when it has work; schedule a tick on
    /// main. Reads the global app pointer directly — must NOT touch
    /// `GhosttyRuntime.shared` (see `gGhosttyApp`).
    nonisolated static func wakeup() {
        DispatchQueue.main.async {
            if let app = gGhosttyApp { ghostty_app_tick(app) }
        }
    }
}

/// An `NSView` hosting one libghostty surface scoped to a working directory.
@MainActor
final class GhosttySurfaceView: NSView {
    private var surface: ghostty_surface_t?

    init(descriptor: TerminalLaunchDescriptor) {
        super.init(frame: .zero)
        wantsLayer = true

        let app = GhosttyRuntime.shared.app
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.wait_after_command = true

        descriptor.workingDirectory.path.withCString { cwd in
            config.working_directory = cwd
            descriptor.command.withCString { command in
                config.command = command
                surface = ghostty_surface_new(app, &config)
            }
        }
        guard let surface else {
            fatalError("ghostty_surface_new returned nil for \(descriptor.workingDirectory.path).")
        }
        // Receive config updates when the app theme changes.
        GhosttyRuntime.shared.register(surface, for: self)
        // libghostty drives its own rendering (internal vsync/CVDisplayLink tied
        // to this NSView) — we must NOT call ghostty_surface_draw ourselves.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setFocused(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func terminate() {
        if let surface {
            GhosttyRuntime.shared.unregister(self)
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    // MARK: - Sizing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        ghostty_surface_set_content_scale(surface, scale, scale)
        let backing = convertToBacking(bounds).size
        ghostty_surface_set_size(surface, UInt32(max(0, backing.width)), UInt32(max(0, backing.height)))
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        setFocused(true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        setFocused(false)
        return super.resignFirstResponder()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        forwardKey(event, action: GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        forwardKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    private func forwardKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return super.keyDown(with: event) }
        let text = event.characters ?? ""
        text.withCString { cstr in
            var key = ghostty_input_key_s()
            key.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : action
            key.mods = Self.mods(from: event.modifierFlags)
            key.consumed_mods = ghostty_input_mods_e(rawValue: 0)
            key.keycode = UInt32(event.keyCode)
            key.text = cstr
            key.unshifted_codepoint = 0
            key.composing = false
            _ = ghostty_surface_key(surface, key)
        }
    }

    private static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) { forwardMouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT) }
    override func mouseUp(with event: NSEvent) { forwardMouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    override func rightMouseDown(with event: NSEvent) { forwardMouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { forwardMouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }
    override func mouseDragged(with event: NSEvent) { forwardMousePos(event) }
    override func mouseMoved(with event: NSEvent) { forwardMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var mods = ghostty_input_scroll_mods_t()
        if event.hasPreciseScrollingDeltas { mods = 1 }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
    }

    private func forwardMouseButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(from: event.modifierFlags))
    }

    private func forwardMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, Self.mods(from: event.modifierFlags))
    }
}

/// Bridges a libghostty surface view to the app's `TerminalSurface` protocol.
@MainActor
final class GhosttyTerminalSurface: TerminalSurface {
    let nsView: NSView
    private let surfaceView: GhosttySurfaceView

    init(descriptor: TerminalLaunchDescriptor) {
        surfaceView = GhosttySurfaceView(descriptor: descriptor)
        nsView = surfaceView
    }

    func setFocused(_ focused: Bool) { surfaceView.setFocused(focused) }
    func terminate() { surfaceView.terminate() }
}

@MainActor
struct GhosttyTerminalFactory: TerminalSurfaceFactory {
    static let shared = GhosttyTerminalFactory()
    func makeSurface(descriptor: TerminalLaunchDescriptor) -> any TerminalSurface {
        GhosttyTerminalSurface(descriptor: descriptor)
    }
}
