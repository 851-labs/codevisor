//  The terminal pane: owns one long-lived TerminalSurface (so its shell and
//  scrollback survive tab switches, panel close, and navigation) plus the
//  Pane lifecycle glue. Successor of the pre-pane-group TerminalSession.

import AppKit
import Foundation
import Observation
import SwiftUI
import HerdManCore

@MainActor
@Observable
final class TerminalPane: Pane, Identifiable {
    let id: UUID
    let kind: PaneKind = .terminal
    let descriptor: TerminalLaunchDescriptor

    /// Set by the pane group; forwarded from the surface's keyboard shortcuts.
    @ObservationIgnored var onGroupCommand: ((PaneGroupCommand) -> Void)?

    @ObservationIgnored private var _surface: (any TerminalSurface)?

    /// Bumped whenever the surface is replaced (Restart Terminal). Observed by
    /// the pane view so SwiftUI re-attaches the freshly created surface view.
    private(set) var surfaceGeneration = 0

    init(context: PaneContext) {
        self.id = context.paneId
        self.descriptor = TerminalLaunchDescriptor.make(
            session: context.session,
            project: context.project,
            machine: context.machine,
            terminalKey: context.terminalKey,
            attachOnly: context.attachOnly
        )
    }

    /// The surface, created lazily on first use (first time the pane shows).
    func ensureSurface() -> any TerminalSurface {
        if let surface = _surface { return surface }
        let surface = TerminalRuntime.factory.makeSurface(descriptor: descriptor)
        surface.onRestartRequest = { [weak self] in self?.restart() }
        surface.onPaneCommand = { [weak self] command in self?.onGroupCommand?(command) }
        _surface = surface
        return surface
    }

    /// Kills the terminal — both the local surface and this pane's PTY on the
    /// herdman server (which otherwise deliberately survives surface teardown
    /// so shells persist across app restarts) — then recreates a fresh surface.
    /// Agent-owned terminals only reattach: the process is the agent's, so
    /// "restart" rebuilds the viewer, never the process.
    func restart() {
        _surface?.terminate()
        _surface = nil

        if descriptor.attachOnly {
            surfaceGeneration += 1
            return
        }
        Task {
            // Kill the server-side shell BEFORE the new surface's proxy spawns,
            // or the proxy would just reattach to the old shell.
            await deleteServerShell()
            surfaceGeneration += 1
        }
    }

    // MARK: - Pane hooks

    func makeView() -> AnyView {
        AnyView(TerminalPaneView(pane: self))
    }

    func focus() {
        let surface = ensureSurface()
        if let view = surface.nsView as? Ghostty.SurfaceView {
            // Retries until the view is attached to a window (new panes mount
            // a runloop later); becomeFirstResponder updates the focus state.
            // Never set the focus flag manually here: if first-responder
            // assignment fails, a stale focused=true makes the surface eat
            // ⌘-key equivalents meant for the composer/menus.
            Ghostty.moveFocus(to: view)
        } else {
            surface.nsView.window?.makeFirstResponder(surface.nsView)
        }
    }

    func visibilityChanged(_ visible: Bool) {
        // Hidden panes must not hold terminal focus; becoming visible does not
        // steal focus (that's the explicit focus() hook's job).
        if !visible {
            _surface?.setFocused(false)
        }
    }

    /// Tab closed: tear down the surface AND kill the server-side shell.
    func willDelete() async {
        _surface?.terminate()
        _surface = nil
        await deleteServerShell()
    }

    /// App-side teardown only; the shell survives on the server for
    /// reattachment (same semantics as quitting the app).
    func detach() {
        _surface?.terminate()
        _surface = nil
    }

    // MARK: - Server shell lifecycle

    private func deleteServerShell() async {
        let machine = descriptor.machine
        var request = URLRequest(
            url: machine.baseURL
                .appendingPathComponent("v1/terminals/session")
                // ":" is urlPathAllowed so the synthetic "<session>:<pane>" key
                // passes through raw; the server decodes the segment either way.
                .appendingPathComponent(descriptor.terminalKey)
        )
        request.httpMethod = "DELETE"
        if let token = machine.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await URLSession.shared.data(for: request)
    }
}

/// The terminal pane's content: just the surface on the theme background.
struct TerminalPaneView: View {
    @Environment(\.theme) private var theme
    var pane: TerminalPane

    var body: some View {
        TerminalSurfaceView(pane: pane)
            // Re-attach when the surface is replaced (Restart Terminal).
            .id(pane.surfaceGeneration)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.terminalBackground)
    }
}
