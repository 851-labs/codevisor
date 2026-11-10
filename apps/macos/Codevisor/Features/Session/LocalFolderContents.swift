import Foundation

nonisolated struct LocalFolderContents: Sendable, Equatable {
  let files: [String]
  let emptyFolders: [String]

  private static let skippedNames: Set<String> = [".DS_Store"]
  private static let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]

  static func isFolder(_ url: URL) throws -> Bool {
    try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
  }

  @concurrent
  static func read(_ folder: URL) async throws -> LocalFolderContents {
    var files: [String] = []
    var folders: [String] = []
    for item in try items(in: folder) {
      let values = try item.url.resourceValues(forKeys: Set(keys))
      if values.isDirectory == true {
        folders.append(item.relativePath)
      } else if values.isRegularFile == true, !skippedNames.contains(item.url.lastPathComponent) {
        files.append(item.relativePath)
      }
    }
    return LocalFolderContents(files: files, emptyFolders: folders.filter { !containsFile($0, files) })
  }

  private struct Item {
    let url: URL
    let relativePath: String
  }

  private static func items(in folder: URL) throws -> [Item] {
    let root = folder.standardizedFileURL.path
    guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
      throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
    }
    return enumerator.compactMap { $0 as? URL }.map { url in
      Item(url: url, relativePath: String(url.standardizedFileURL.path.dropFirst(root.count + 1)))
    }
  }

  private static func containsFile(_ folder: String, _ files: [String]) -> Bool {
    files.contains { $0.hasPrefix(folder + "/") }
  }
}
