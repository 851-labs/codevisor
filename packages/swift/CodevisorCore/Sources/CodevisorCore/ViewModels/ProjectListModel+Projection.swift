import Foundation

extension ProjectListModel {
  func applyProjection(
    projects nextProjects: [Project], sessions nextSessions: [ChatSession],
    origin: SessionAttentionTransition.Origin
  ) {
    if nextProjects != projects { projects = nextProjects }
    guard nextSessions != sessions else { return }
    let previous = sessions
    sessions = nextSessions
    emitAttentionTransitions(from: previous, to: nextSessions, origin: origin)
  }
}
