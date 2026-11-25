import Foundation

@MainActor
final class FileEditorSessions {
  private var sessions: [String: FileEditorSession] = [:]
  private var order: [String] = []
  private let capacity: Int
  private let document: (String) -> FileDocumentModel
  var onEdit: (() -> Void)?
  var access: FileAccess {
    didSet { for session in sessions.values { session.access = access } }
  }

  init(capacity: Int = 32, access: FileAccess = .editing, document: @escaping (String) -> FileDocumentModel) {
    self.capacity = capacity
    self.access = access
    self.document = document
  }

  func editor(for path: String) -> FileEditorSession {
    order.removeAll { $0 == path }
    order.append(path)
    if let session = sessions[path] { return session }
    let session = FileEditorSession(document: document(path), access: access)
    session.onEdit = { [weak self] in self?.onEdit?() }
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
