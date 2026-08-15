import CodevisorCore
import SwiftUI

/// Keeps the draft-only file-browser route out of Home's typed navigation
/// stack. The new-chat sheet uses a type-erased NavigationPath and owns this
/// destination at its root; regular workspaces must never register it.
struct InitialProjectNavigationDestination: ViewModifier {
    let isEnabled: Bool
    let onPick: (String) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.navigationDestination(for: RemoteDirectory.self) { directory in
                RemoteDirectoryScreen(directory: directory, onPick: onPick)
            }
        } else {
            content
        }
    }
}
