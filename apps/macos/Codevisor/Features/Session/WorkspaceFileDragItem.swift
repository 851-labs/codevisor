import CodevisorClient
import Foundation
import UniformTypeIdentifiers

nonisolated enum WorkspaceFileDragItem {
  static func provider(
    for entry: ServerFileEntry, isLocal: Bool, client: any CodevisorServerClienting
  ) -> NSItemProvider {
    let naming = DragNaming(entry)
    let provider = NSItemProvider()
    provider.suggestedName = naming.suggestedName
    provider.registerFileRepresentation(
      forTypeIdentifier: naming.type.identifier, fileOptions: [], visibility: .all
    ) { completion in
      deliver(entry, isLocal: isLocal, client: client, completion: completion)
    }
    return provider
  }

  private static func deliver(
    _ entry: ServerFileEntry, isLocal: Bool, client: any CodevisorServerClienting,
    completion: @escaping @Sendable (URL?, Bool, (any Error)?) -> Void
  ) -> Progress? {
    guard !isLocal else {
      completion(URL(fileURLWithPath: entry.path), false, nil)
      return nil
    }

    let progress = Progress(totalUnitCount: 1)
    Task {
      do {
        let url = try await WorkspaceFileTransferOperations.materialize(
          entry, into: try stagingDirectory(), client: client)
        completion(url, false, nil)
      } catch {
        completion(nil, false, error)
      }
      progress.completedUnitCount = 1
    }
    return progress
  }

  private static func stagingDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codevisor-file-drags", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
