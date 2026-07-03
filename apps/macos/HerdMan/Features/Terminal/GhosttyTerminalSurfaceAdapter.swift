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
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        sizeDidChange(frame.size)
    }
}

/// A terminal surface backed by the vendored upstream Ghostty surface view.
@MainActor
final class GhosttyTerminalSurface: TerminalSurface {
    private var surfaceView: Ghostty.SurfaceView?
    private var cancellables = Set<AnyCancellable>()

    var nsView: NSView { surfaceView ?? NSView() }

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
        HerdManGhosttyApp.shared.register(view)
        surfaceView = view

        // Upstream applies the surface's published pointer style from its
        // SwiftUI wrapper (not vendored); mirror that here.
        view.$pointerStyle
            .combineLatest(view.$mouseOverSurface)
            .sink { style, over in
                if over { style.cursor.set() }
            }
            .store(in: &cancellables)
    }

    func setFocused(_ focused: Bool) {
        surfaceView?.focusDidChange(focused)
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
