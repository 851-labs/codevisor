//  Bridges the vendored Ghostty.SurfaceView (upstream Ghostty's full AppKit
//  surface: NSTextInputClient/IME, performKeyEquivalent, tracking areas,
//  clipboard, DPI handling) to HerdMan's TerminalSurface protocol.

import AppKit
import Combine
import GhosttyKit
import os

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

        let view = Ghostty.SurfaceView(HerdManGhosttyApp.shared.app, baseConfig: config)
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
