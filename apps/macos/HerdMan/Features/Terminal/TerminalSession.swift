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

    init(id: UUID, descriptor: TerminalLaunchDescriptor) {
        self.id = id
        self.descriptor = descriptor
    }

    /// The surface, created lazily on first use (first time the panel opens).
    func ensureSurface() -> any TerminalSurface {
        if let surface = _surface { return surface }
        let surface = TerminalRuntime.factory.makeSurface(descriptor: descriptor)
        _surface = surface
        return surface
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
