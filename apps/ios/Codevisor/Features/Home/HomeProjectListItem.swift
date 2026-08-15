import CodevisorCore
import Foundation

struct HomeProjectListItem: Identifiable {
    let project: Project
    let sessions: [ChatSession]

    var id: UUID { project.id }
}
