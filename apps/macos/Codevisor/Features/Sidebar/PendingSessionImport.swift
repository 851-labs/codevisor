import CodevisorCore
import Foundation

struct PendingSessionImport: Identifiable {
  let project: Project
  let sessions: [ImportedSession]

  var id: UUID { project.id }
}
