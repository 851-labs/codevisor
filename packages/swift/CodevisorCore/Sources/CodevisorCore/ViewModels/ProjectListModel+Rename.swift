import Foundation

extension ProjectListModel {
  @discardableResult
  public func renameSession(
    _ session: ChatSession, to title: String, errorReporter: ErrorReporter = .shared
  ) -> Task<Void, Never>? {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, var current = self.session(session.id, serverId: session.serverId) else { return nil }
    current.title = title
    enqueue(.renameSession(current), serverId: session.serverId)
    return nil
  }
}
