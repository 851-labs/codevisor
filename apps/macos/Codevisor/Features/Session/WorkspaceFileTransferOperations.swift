import CodevisorClient
import Foundation

nonisolated enum WorkspaceFileTransferOperations {
  private static let parallelUploads = 4

  static func upload(
    _ local: URL, into directory: String, client: any CodevisorServerClienting
  ) async throws -> String {
    let destination = remotePath(directory, local.lastPathComponent)
    guard try LocalFolderContents.isFolder(local) else {
      return try await client.putFile(from: local, toPath: destination, conflict: .keepBoth)
    }

    let folder = try await client.createFolder(path: destination, conflict: .keepBoth)
    try await uploadContents(of: local, into: folder, client: client)
    return folder
  }

  static func materialize(
    _ entry: ServerFileEntry, into directory: URL, client: any CodevisorServerClienting
  ) async throws -> URL {
    let destination = directory.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
    guard entry.isDirectory else {
      try await client.downloadFile(path: entry.path, to: destination)
      return destination
    }

    let archive = directory.appendingPathComponent(".\(UUID().uuidString).tar")
    defer { try? FileManager.default.removeItem(at: archive) }
    try await client.downloadArchive(path: entry.path, to: archive)
    try await TarArchive.extract(archive, into: directory)
    return destination
  }

  private static func uploadContents(
    of local: URL, into folder: String, client: any CodevisorServerClienting
  ) async throws {
    let contents = try await LocalFolderContents.read(local)
    for directory in contents.emptyFolders {
      _ = try await client.createFolder(path: remotePath(folder, directory), conflict: .replace)
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for (index, file) in contents.files.enumerated() {
        if index >= parallelUploads { try await group.next() }
        group.addTask {
          _ = try await client.putFile(
            from: local.appendingPathComponent(file), toPath: remotePath(folder, file), conflict: .replace)
        }
      }
      try await group.waitForAll()
    }
  }

  private static func remotePath(_ directory: String, _ relative: String) -> String {
    directory.hasSuffix("/") ? directory + relative : "\(directory)/\(relative)"
  }
}
