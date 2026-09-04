import CodevisorCore
import Foundation

/// One by-project row: a repository linked across machines, with every
/// member's chats. Keyed by the group's primary (oldest) record so the
/// UUID-based expansion and manual-order preferences keep working.
struct HomeProjectListItem: Identifiable {
  let group: ProjectGroup
  let sessions: [ChatSession]

  var id: UUID { group.primary.id }
}
