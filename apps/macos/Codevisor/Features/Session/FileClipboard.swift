import AppKit
import CodevisorClient

enum FileClipboard {
  static func write(_ urls: [URL]) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
  }

  static func writePaths(_ paths: [String]) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
  }

  nonisolated static func stage(
    _ entries: [ServerFileEntry], isLocal: Bool, client: any CodevisorServerClienting
  ) async throws -> [URL] {
    guard !isLocal else { return entries.map { URL(fileURLWithPath: $0.path) } }

    let directory = try freshStagingDirectory()
    var staged: [URL] = []
    for entry in entries {
      staged.append(try await WorkspaceFileTransferOperations.materialize(entry, into: directory, client: client))
    }
    return staged
  }

  private nonisolated static func freshStagingDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codevisor-file-copies", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
