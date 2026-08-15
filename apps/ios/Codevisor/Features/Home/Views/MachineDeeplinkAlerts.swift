import CodevisorCore
import SwiftUI

/// The confirm + error alerts for `codevisor://add-machine` deeplinks,
/// mirroring the macOS handler. Applied twice — to the home content and to
/// the onboarding cover — with `isActive` selecting whichever is the visible
/// presentation context, so the same pending state presents in exactly one
/// place.
struct MachineDeeplinkAlerts: ViewModifier {
    @Binding var pending: MachineDeeplink?
    @Binding var error: String?
    let isActive: Bool
    let confirm: (MachineDeeplink) -> Void

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
                Button("Add \(deeplink.displayName)") { confirm(deeplink) }
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
