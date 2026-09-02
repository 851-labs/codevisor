import CodevisorCore
import Foundation

/// Existing harness sessions found in a just-added project folder, pending
/// the user's decision to import them.
struct PendingSessionImport: Identifiable {
  let project: Project
  let sessions: [ImportedSession]

  var id: UUID { project.id }
}
