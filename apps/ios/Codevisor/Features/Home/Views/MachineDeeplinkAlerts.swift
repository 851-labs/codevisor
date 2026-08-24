import CodevisorCore
import SwiftUI

/// The confirm + error alerts for `codevisor://add-machine` deeplinks,
/// mirroring the macOS handler. Applied twice — to the home content and to
/// the onboarding cover — with `isActive` selecting whichever is the visible
/// presentation context, so the same pending state presents in exactly one
/// place.
struct MachineDeeplinkAlerts: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Binding var pending: MachineDeeplink?
    @Binding var error: String?
    let isActive: Bool

    /// The config-sync opt-out only appears when a fleet already exists —
    /// the first machine has nothing to sync yet.
    private var showsSyncChoice: Bool {
        environment.machines.allMachines.contains { !$0.isLocal }
    }

    /// Adds the machine from a confirmed deeplink, selects it, and records
    /// the onboarding sync choice on the machine itself.
    private func confirm(_ link: MachineDeeplink, _ syncConfig: Bool) {
        pending = nil
        Task {
            do {
                let machine = try await environment.machines.addRemoteValidating(
                    host: link.hostWithPort,
                    name: link.name,
                    token: link.token,
                    syncConfig: syncConfig
                )
                environment.machines.selectMachine(machine.id)
                await environment.prepareSelectedMachine()
            } catch let failure {
                error = ErrorReporter.userFacingMessage(for: failure)
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "Add Remote Machine?",
                isPresented: Binding(
                    get: { isActive && pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                presenting: pending
            ) { deeplink in
                Button("Add \(deeplink.displayName)") { confirm(deeplink, true) }
                if showsSyncChoice {
                    Button("Add Without Syncing Config") { confirm(deeplink, false) }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { deeplink in
                Text(
                    """
                    “\(deeplink.displayName)” (\(deeplink.hostWithPort)) will be added to your \
                    machines. Codevisor will be able to run agents and read files on it.
                    """
                )
            }
            .alert(
                "Couldn't Add Machine",
                isPresented: Binding(
                    get: { isActive && error != nil },
                    set: { if !$0 { error = nil } }
                ),
                presenting: error
            ) { _ in
                Button("OK", role: .cancel) { error = nil }
            } message: { message in
                Text(message)
            }
    }
}
