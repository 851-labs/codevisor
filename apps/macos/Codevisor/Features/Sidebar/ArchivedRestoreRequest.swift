import CodevisorCore
import Foundation

/// A pending "restore this?" confirmation. Clicking an archived row asks
/// before acting: the row looks exactly like a live one, so an unguarded click
/// would silently un-archive whatever the user was only trying to read.
struct ArchivedRestoreRequest: Identifiable {
  enum Target {
    case project(Project)
    case session(ChatSession)
  }

  let target: Target

  var id: UUID {
    switch target {
    case let .project(project): project.id
    case let .session(session): session.id
    }
  }

  var name: String {
    switch target {
    case let .project(project): project.name
    case let .session(session): session.title
    }
  }

  var kind: String {
    switch target {
    case .project: "project"
    case .session: "chat"
    }
  }
}
