import SwiftUI

/// How the workspace list groups chats — the same organization options as the
/// macOS sidebar.
enum HomeOrganization: String, CaseIterable {
    case compact
    case byWorkspace
    case byProject

    var title: String {
        switch self {
        case .compact: "Agents"
        case .byWorkspace: "Workspaces"
        case .byProject: "Projects"
        }
    }
}
