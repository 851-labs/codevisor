import Foundation

/// The pane owns a bounded history, so browsing back preserves selection and undo.
/// Closing the pane releases every native editor without discarding shared drafts.
@MainActor
final class FileEditorSessions {
  private var sessions: [String: FileEditorSession] = [:]
  private var order: [String] = []
  private let capacity: Int
  private let document: (String) -> FileDocumentModel

  init(capacity: Int = 32, document: @escaping (String) -> FileDocumentModel) {
    self.capacity = capacity
    self.document = document
  }

  func editor(for path: String) -> FileEditorSession {
    order.removeAll { $0 == path }
    order.append(path)
    if let session = sessions[path] { return session }
    let session = FileEditorSession(document: document(path))
    sessions[path] = session
    while order.count > capacity { sessions.removeValue(forKey: order.removeFirst())?.close() }
    return session
  }

  func close() {
    for session in sessions.values { session.close() }
    sessions.removeAll()
    order.removeAll()
  }
}
