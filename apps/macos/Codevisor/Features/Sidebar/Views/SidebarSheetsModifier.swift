import CodevisorCore
import SwiftUI

/// The add-remote-machine sheet owned by the sidebar.
struct SidebarSheetsModifier: ViewModifier {
  @Binding var showingRemoteMachine: Bool
  /// Returns an error message to show in the sheet, or nil on success.
  /// The Bool is the config-sync opt-in.
  let onAddRemoteMachine: (String, String?, String?, Bool) async -> String?

  func body(content: Content) -> some View {
    content
      .sheet(isPresented: $showingRemoteMachine) {
        RemoteMachineSheet { host, name, token, syncConfig in
          await onAddRemoteMachine(host, name, token, syncConfig)
        }
      }
  }
}
