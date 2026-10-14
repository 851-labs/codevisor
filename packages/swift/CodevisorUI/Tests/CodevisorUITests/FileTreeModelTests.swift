import CodevisorClient
import Foundation
import Testing

@testable import CodevisorUI

@MainActor struct FileTreeModelTests {
  /// An in-memory machine: folder path to listing, and the folders it was asked for.
  @MainActor final class Disk {
    var folders: [String: [ServerFileEntry]]
    var listed: [String] = []
    init(_ folders: [String: [ServerFileEntry]]) { self.folders = folders }
    func list(_ path: String) -> [ServerFileEntry] {
      listed.append(path)
      return folders[path] ?? []
    }
  }

  private static func folder(_ path: String) -> ServerFileEntry {
    ServerFileEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: true)
  }

  private static func file(_ path: String) -> ServerFileEntry {
    ServerFileEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: false)
  }

  private func tree(_ disk: Disk) -> FileTreeModel {
    FileTreeModel(root: "/repo") { path in disk.list(path) }
  }

  private func visible(_ tree: FileTreeModel) -> [String] {
    tree.rows.map { String(repeating: "  ", count: $0.depth) + $0.entry.name }
  }

  @Test func collapsingAFolderHidesItsContentsAndReopeningRestoresNestedFolders() async {
    let disk = Disk([
      "/repo": [Self.folder("/repo/.git"), Self.folder("/repo/Sources"), Self.file("/repo/README.md")],
      "/repo/Sources": [Self.folder("/repo/Sources/App"), Self.file("/repo/Sources/main.swift")],
      "/repo/Sources/App": [Self.file("/repo/Sources/App/App.swift")],
    ])
    let tree = tree(disk)
    await tree.refresh()
    #expect(visible(tree) == ["Sources", "README.md"])

    await tree.toggle("/repo/Sources")
    await tree.toggle("/repo/Sources/App")
    #expect(visible(tree) == ["Sources", "  App", "    App.swift", "  main.swift", "README.md"])

    await tree.toggle("/repo/Sources")
    #expect(visible(tree) == ["Sources", "README.md"])
    await tree.toggle("/repo/Sources")
    #expect(visible(tree) == ["Sources", "  App", "    App.swift", "  main.swift", "README.md"])
  }

  @Test func refreshPicksUpNewFilesInOpenFoldersOnly() async {
    let disk = Disk([
      "/repo": [Self.folder("/repo/docs"), Self.folder("/repo/src")],
      "/repo/docs": [Self.folder("/repo/docs/guides")],
      "/repo/docs/guides": [],
      "/repo/src": [],
    ])
    let tree = tree(disk)
    await tree.refresh()
    await tree.toggle("/repo/docs")
    await tree.toggle("/repo/docs/guides")
    await tree.toggle("/repo/src")
    await tree.toggle("/repo/docs")
    disk.folders["/repo/src"] = [Self.file("/repo/src/new.ts")]
    disk.listed = []

    await tree.refresh()

    #expect(Set(disk.listed) == ["/repo", "/repo/src"])
    #expect(visible(tree) == ["docs", "src", "  new.ts"])
  }
}
