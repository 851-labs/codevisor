import CodevisorCore
import SwiftUI

/// The add-remote-machine sheet owned by the sidebar.
struct SidebarSheetsModifier: ViewModifier {
    @Binding var showingRemoteMachine: Bool
    /// Returns an error message to show in the sheet, or nil on success.
    let onAddRemoteMachine: (String, String?, String?) async -> String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingRemoteMachine) {
                RemoteMachineSheet { host, name, token in
                    await onAddRemoteMachine(host, name, token)
                }
            }
    }
}
