//  Bridges the vendored Ghostty.SurfaceView (upstream Ghostty's full AppKit
//  surface: NSTextInputClient/IME, performKeyEquivalent, tracking areas,
//  clipboard, DPI handling) to HerdMan's TerminalSurface protocol.

import AppKit
import Combine
import GhosttyKit
import os

/// Upstream sizes the libghostty surface only via `sizeDidChange`, called from
/// its SwiftUI wrapper (not vendored). HerdMan drives the view with Auto Layout
/// (TerminalSurfaceView pins it into a container), so forward frame changes —
/// and the initial attach, when the window's backing scale becomes available —
/// into `sizeDidChange` here.
@MainActor
private final class HerdManGhosttySurfaceView: Ghostty.SurfaceView {
    /// Set by the adapter; fired from the context menu's "Restart Terminal".
    var onRestartRequest: (() -> Void)?
    /// Set by the adapter; fired for pane-group shortcuts while focused.
    var onPaneCommand: ((PaneGroupCommand) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        sizeDidChange(frame.size)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        focusForInput()
        super.mouseDown(with: event)
    }

    func focusForInput() {
        if window == nil {
            Ghostty.moveFocus(to: self)
            return
        }
        window?.makeFirstResponder(self)
    }

    /// Pane-group shortcuts, captured only while this surface has keyboard
    /// focus: ⌘⌥←/→ navigate tabs, ⌘T opens a new terminal tab. Everything
    /// else falls through to Ghostty's key handling. The guard is the actual
    /// first-responder relationship — not the published `focused` flag, which
    /// can go stale and would eat composer/menu key equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self, let onPaneCommand {
            // Arrow keys carry implicit .function/.numericPad flags — strip
            // them or the exact-modifier comparisons below never match.
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad])
            if mods == [.command, .option] {
                if event.specialKey == .leftArrow {
                    onPaneCommand(.previousTab)
                    return true
                }
                if event.specialKey == .rightArrow {
                    onPaneCommand(.nextTab)
                    return true
                }
            }
            if mods == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
                if chars == "t" {
                    onPaneCommand(.newTab)
                    return true
                }
                // ⌘J toggles the panel. Handled here rather than relying on
                // the menu command: the SwiftUI focused-scene value is not
                // reliably published while an AppKit view is first responder.
                if chars == "j" {
                    onPaneCommand(.togglePanel)
                    return true
                }
                // ⌘W closes the selected tab while a pane is focused; with
                // focus elsewhere the window's normal ⌘W applies.
                if chars == "w" {
                    onPaneCommand(.closeTab)
                    return true
                }
                if chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
                    onPaneCommand(.selectTab(digit - 1))
                    return true
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        let item = menu.addItem(
            withTitle: "Restart Terminal",
            action: #selector(requestRestart(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.setImageIfDesired(systemSymbolName: "arrow.trianglehead.counterclockwise")
        return menu
    }

    @objc private func requestRestart(_ sender: Any?) {
        onRestartRequest?()
    }
}

/// A terminal surface backed by the vendored upstream Ghostty surface view.
@MainActor
final class GhosttyTerminalSurface: TerminalSurface {
    private var surfaceView: HerdManGhosttySurfaceView?
    private var cancellables = Set<AnyCancellable>()

    var nsView: NSView { surfaceView ?? NSView() }

    var onRestartRequest: (() -> Void)? {
        get { surfaceView?.onRestartRequest }
        set { surfaceView?.onRestartRequest = newValue }
    }

    var onPaneCommand: ((PaneGroupCommand) -> Void)? {
        get { surfaceView?.onPaneCommand }
        set { surfaceView?.onPaneCommand = newValue }
    }

    init(descriptor: TerminalLaunchDescriptor) {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = descriptor.workingDirectory.path
        // Ghostty spawns the herdman-terminal-proxy (not a shell); the proxy
        // bridges to the PTY on the herdman server for this session.
        config.command = descriptor.command
        config.waitAfterCommand = true

        let view = HerdManGhosttySurfaceView(HerdManGhosttyApp.shared.app, baseConfig: config)
        if view.error != nil {
            Ghostty.logger.error("terminal surface creation failed for \(descriptor.workingDirectory.path, privacy: .public)")
        }
        // Upstream initializes SurfaceView.focused to true before the C surface
        // exists. HerdMan mounts the view later, so reset the surface to the real
        // unfocused state now; the next AppKit first-responder transition will
        // publish the matching true focus event to libghostty.
        view.focusDidChange(false)
        HerdManGhosttyApp.shared.register(view)
        surfaceView = view

        // Upstream applies the surface's published pointer style from its
        // SwiftUI wrapper (not vendored); mirror that here.
        view.$pointerStyle
            .combineLatest(view.$mouseOverSurface)
            .sink { style, over in
                if over {
                    style.cursor.set()
                } else {
                    // Reset promptly on exit — otherwise the I-beam lingers
                    // until something else happens to set a cursor.
                    NSCursor.arrow.set()
                }
            }
            .store(in: &cancellables)
    }

    func setFocused(_ focused: Bool) {
        guard let surfaceView else { return }
        if focused {
            surfaceView.focusForInput()
        } else {
            surfaceView.focusDidChange(false)
        }
    }

    func terminate() {
        guard let view = surfaceView else { return }
        HerdManGhosttyApp.shared.unregister(view)
        view.removeFromSuperview()
        cancellables.removeAll()
        // Dropping the last reference releases Ghostty.Surface, whose deinit
        // frees the C surface (and its child proxy process) on the main actor.
        surfaceView = nil
    }
}

@MainActor
struct GhosttyTerminalFactory: TerminalSurfaceFactory {
    static let shared = GhosttyTerminalFactory()
    func makeSurface(descriptor: TerminalLaunchDescriptor) -> any TerminalSurface {
        GhosttyTerminalSurface(descriptor: descriptor)
    }
}
