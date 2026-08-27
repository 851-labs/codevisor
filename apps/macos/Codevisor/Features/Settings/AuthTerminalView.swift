import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

/// The embedded libghostty surface a terminal-kind auth flow renders in,
/// plus the lifecycle handle that tears it down before the server kills
/// the PTY.
struct AuthTerminalView: NSViewRepresentable {
    let terminalKey: String
    let machine: CodevisorMachine
    let lifecycle: AuthTerminalLifecycle

    func makeNSView(context: Context) -> NSView {
        let descriptor = TerminalLaunchDescriptor(
            terminalKey: terminalKey,
            attachOnly: true,
            machine: machine,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            command: TerminalProxyCommand.command(
                server: machine.baseURL,
                terminalKey: terminalKey,
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                token: machine.token,
                attachOnly: true
            )
        )
        let surface = TerminalRuntime.factory.makeSurface(descriptor: descriptor)
        context.coordinator.surface = surface
        lifecycle.attach(surface)
        let container = NSView()
        let child = surface.nsView
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        guard let surface = coordinator.surface else { return }
        surface.terminate()
        coordinator.lifecycle?.detach(surface)
        coordinator.surface = nil
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(lifecycle: lifecycle) }

    final class Coordinator {
        weak var lifecycle: AuthTerminalLifecycle?
        var surface: (any TerminalSurface)?

        init(lifecycle: AuthTerminalLifecycle) {
            self.lifecycle = lifecycle
        }
    }
}

@MainActor
final class AuthTerminalLifecycle {
    private var surface: (any TerminalSurface)?

    func attach(_ surface: any TerminalSurface) {
        self.surface = surface
    }

    func terminate() {
        surface?.terminate()
        surface = nil
    }

    func detach(_ candidate: any TerminalSurface) {
        if let surface, surface === candidate {
            self.surface = nil
        }
    }
}
