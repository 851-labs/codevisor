import CodevisorCore
import Foundation
import Observation

/// One visible row of a file tree: an entry and how deep it sits below the root.
public struct FileTreeRow: Identifiable, Equatable, Sendable {
  public let entry: ServerFileEntry
  public let depth: Int
  public var id: String { entry.path }
}

/// A workspace root as an expandable tree. Folders list lazily, one level at
/// a time, on the machine that owns the files. Collapsing a folder keeps its
/// descendants' expansion, so reopening it restores what was open inside.
@MainActor @Observable
public final class FileTreeModel {
  public let root: String
  public var selection: String?
  public private(set) var expanded: Set<String> = []
  public private(set) var listings: [String: [ServerFileEntry]] = [:]
  public private(set) var errors: [String: String] = [:]
  @ObservationIgnored private var loading: Set<String> = []
  @ObservationIgnored private let list: (String) async throws -> [ServerFileEntry]

  public convenience init(root: String, client: any CodevisorServerClienting) {
    self.init(root: root) { path in try await client.fileEntries(path: path, showHidden: true).entries }
  }

  init(root: String, list: @escaping (String) async throws -> [ServerFileEntry]) {
    self.root = root
    self.list = list
  }

  public var rootName: String { (root as NSString).lastPathComponent }

  public var relativeSelection: String? { selection.map(relativePath) }

  public func relativePath(_ path: String) -> String {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard path.hasPrefix(prefix) else { return path }
    return String(path.dropFirst(prefix.count))
  }

  /// The rows on screen: every entry under the root and its open folders.
  public var rows: [FileTreeRow] {
    var rows: [FileTreeRow] = []
    func append(_ directory: String, depth: Int) {
      for entry in children(of: directory) {
        rows.append(FileTreeRow(entry: entry, depth: depth))
        if entry.isDirectory, expanded.contains(entry.path) { append(entry.path, depth: depth + 1) }
      }
    }
    append(root, depth: 0)
    return rows
  }

  /// A folder's listing. Git's own directory is never browsable.
  public func children(of directory: String) -> [ServerFileEntry] {
    (listings[directory] ?? []).filter { $0.name != ".git" }
  }

  public func isLoaded(_ directory: String) -> Bool { listings[directory] != nil }

  public func entry(at path: String) -> ServerFileEntry? {
    let parent = (path as NSString).deletingLastPathComponent
    return listings[parent]?.first { $0.path == path }
  }

  public func setExpanded(_ directory: String, _ isExpanded: Bool) async {
    if isExpanded {
      expanded.insert(directory)
      await load(directory)
    } else {
      expanded.remove(directory)
    }
  }

  public func toggle(_ directory: String) async {
    await setExpanded(directory, !expanded.contains(directory))
  }

  /// Re-lists the root and every folder that is open on screen. Folders
  /// hidden inside a collapsed parent refresh when they show again.
  public func refresh() async {
    var visible = [root]
    var pending = [root]
    while let directory = pending.popLast() {
      for entry in children(of: directory) where entry.isDirectory && expanded.contains(entry.path) {
        visible.append(entry.path)
        pending.append(entry.path)
      }
    }
    for directory in visible { await load(directory) }
  }

  func load(_ directory: String) async {
    guard !loading.contains(directory) else { return }
    loading.insert(directory)
    defer { loading.remove(directory) }
    do {
      let entries = try await list(directory)
      if listings[directory] != entries { listings[directory] = entries }
      errors[directory] = nil
    } catch {
      if !isTaskCancellation(error) { errors[directory] = serverErrorMessage(error) }
    }
  }
}
