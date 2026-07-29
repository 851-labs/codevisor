import SwiftUI
import AppKit
import CodevisorCore

/// Adds "Copy Connection Token" to the app menu next to Settings.
struct MachineCommands: Commands {
    let machines: MachineController

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            CopyConnectionTokenMenuItem(machines: machines)
        }
    }
}

private struct CopyConnectionTokenMenuItem: View {
    let machines: MachineController

    var body: some View {
        Button("Copy Connection Token") { copyToken() }
    }

    /// Issues a fresh token from this Mac's server and puts it on the
    /// clipboard. Failure gets an alert; success is silent, like any Copy.
    private func copyToken() {
        Task { @MainActor in
            do {
                let token = try await machines.issueLocalConnectionToken()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token, forType: .string)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't issue a connection token"
                alert.informativeText = "This Mac's Codevisor server isn't running."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
