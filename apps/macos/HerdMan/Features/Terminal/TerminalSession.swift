import Foundation
import Observation
import HerdManCore

/// The per-session terminal: owns a single long-lived `TerminalSurface` (so its
/// shell/scrollback survive closing the panel and navigating away) plus the
/// panel's open/height state. One terminal per session.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id: UUID
    let descriptor: TerminalLaunchDescriptor
    /// Panel open/closed + height (see `TerminalPanelState`).
    var panel = TerminalPanelState()

    @ObservationIgnored private var _surface: (any TerminalSurface)?

    /// Bumped whenever the surface is replaced (Restart Terminal). Observed by
    /// the panel so SwiftUI re-attaches the freshly created surface view.
    private(set) var surfaceGeneration = 0

    init(id: UUID, descriptor: TerminalLaunchDescriptor) {
        self.id = id
        self.descriptor = descriptor
    }

    /// The surface, created lazily on first use (first time the panel opens).
    func ensureSurface() -> any TerminalSurface {
        if let surface = _surface { return surface }
        let surface = TerminalRuntime.factory.makeSurface(descriptor: descriptor)
        surface.onRestartRequest = { [weak self] in self?.restart() }
        _surface = surface
        return surface
    }

    /// Kills the terminal — both the local surface and the session's PTY on the
    /// herdman server (which otherwise deliberately survives surface teardown so
    /// shells persist across app restarts) — then recreates a fresh surface.
    func restart() {
        _surface?.terminate()
        _surface = nil

        let machine = descriptor.machine
        let sessionId = descriptor.sessionId
        Task {
            // Kill the server-side shell BEFORE the new surface's proxy spawns,
            // or the proxy would just reattach to the old shell.
            var request = URLRequest(
                url: machine.baseURL.appendingPathComponent("v1/terminals/session/\(sessionId.uuidString)")
            )
            request.httpMethod = "DELETE"
            if let token = machine.token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            _ = try? await URLSession.shared.data(for: request)
            surfaceGeneration += 1
        }
    }

    func setFocused(_ focused: Bool) {
        _surface?.setFocused(focused)
    }

    /// Toggles the panel, returning which area should receive focus.
    @discardableResult
    func togglePanel() -> SessionFocusTarget {
        panel.toggle()
    }

    func terminate() {
        _surface?.terminate()
        _surface = nil
    }
}
