import CodevisorCore
import Observation
import SwiftUI

@MainActor @Observable
final class FileExplorerModel {
  let root: String
  var expanded: Set<String>
  var listings: [String: [ServerFileEntry]] = [:]
  var loading: Set<String> = []
  var errors: [String: String] = [:]
  var filter = ""
  private let client: any CodevisorServerClienting
  private let preferenceKey: String

  init(root: String, machineId: String, client: any CodevisorServerClienting) {
    self.root = root; self.client = client
    preferenceKey = "fileExplorer.\(machineId).\(root)"
    expanded = Set(UserDefaults.standard.stringArray(forKey: preferenceKey) ?? [])
  }

  var rootName: String { (root as NSString).lastPathComponent }

  func relativePath(_ path: String) -> String {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard path.hasPrefix(prefix) else { return path }
    return String(path.dropFirst(prefix.count))
  }

  func searchFiles(in directory: String, query: String) async throws -> ServerFileSearch {
    try await client.searchFileEntries(path: directory, query: query)
  }

  func setExpanded(_ path: String, to value: Bool) {
    if value { expanded.insert(path) } else { expanded.remove(path) }
    UserDefaults.standard.set(Array(expanded), forKey: preferenceKey)
  }

  func load(_ path: String) async {
    guard !loading.contains(path) else { return }
    loading.insert(path)
    defer { loading.remove(path) }
    do {
      listings[path] = try await client.fileEntries(path: path, showHidden: true).entries
      errors[path] = nil
    } catch {
      if !isTaskCancellation(error) { errors[path] = serverErrorMessage(error) }
    }
  }

  func toggle(_ path: String) async {
    let value = !expanded.contains(path)
    setExpanded(path, to: value)
    if value { await load(path) }
  }

  func refresh(selectedPath: String) async {
    // Reveal the selected file without loading the entire repository.
    var parent = (selectedPath as NSString).deletingLastPathComponent
    while parent.hasPrefix(root + "/"), parent != root {
      expanded.insert(parent)
      parent = (parent as NSString).deletingLastPathComponent
    }
    await load(root)
    for path in expanded.sorted() { await load(path) }
  }
}
