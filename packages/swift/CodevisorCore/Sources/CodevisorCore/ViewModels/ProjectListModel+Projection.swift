import Foundation

extension ProjectListModel {
  /// Installs the rows `NavigationStore` derived. This is the only way
  /// `projects` and `sessions` change: the model shows the projection, it
  /// doesn't keep its own copy of server state.
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
