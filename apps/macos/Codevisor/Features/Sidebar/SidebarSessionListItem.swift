import CodevisorCore
import Foundation

struct SidebarSessionListItem: Identifiable {
    let session: ChatSession
    let project: Project

    var id: UUID { session.id }
}
