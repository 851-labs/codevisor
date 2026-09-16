import CodevisorCore
import CryptoKit
import Foundation

@MainActor
public final class FileDocumentStore {
  public static let shared = FileDocumentStore()
  private final class Reference {
    weak var document: FileDocumentModel?
    init(_ document: FileDocumentModel) { self.document = document }
  }
  private var documents: [String: Reference] = [:]
  private var retained: [String: FileDocumentModel] = [:]
  private var accessOrder: [String] = []
  private let capacity: Int

  init(capacity: Int = 32) { self.capacity = capacity }

  public func document(machineId: String, path: String, client: any CodevisorServerClienting) -> FileDocumentModel {
    let key = machineId + ":" + path
    return document(key: key) {
      let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
      let draftURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Codevisor/FileDrafts/\(hash).json")
      return FileDocumentModel(
        path: path, draftURL: draftURL,
        read: { try await FileDocumentLocation.read(path: path, client: client) },
        write: { try await client.saveDocument(path: path, content: $0, version: $1) })
    }
  }

  func document(key: String, make: () -> FileDocumentModel) -> FileDocumentModel {
    documents = documents.filter { $0.value.document != nil }
    let document = documents[key]?.document ?? make()
    documents[key] = Reference(document)
    retained[key] = document
    accessOrder.removeAll { $0 == key }
    accessOrder.append(key)
    // Panes retain their own documents. Evicting a clean cache entry never
    // creates a second buffer for a document still owned by an editor session.
    while retained.count > capacity,
      let expired = accessOrder.first(where: {
        guard $0 != key, let document = retained[$0] else { return false }
        return !document.isDirty && !document.isSaving && document.draftError == nil
      })
    {
      retained.removeValue(forKey: expired)
      accessOrder.removeAll { $0 == expired }
    }
    return document
  }
}
