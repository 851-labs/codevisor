import CodevisorClient
import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceInspectorFileTreeModel {
  struct Row: Identifiable {
    let entry: ServerFileEntry
    let depth: Int

    var id: String { entry.path }
  }

  private static let hiddenNames: Set<String> = [".git"]

  private(set) var root: String?
  private(set) var listings: [String: [ServerFileEntry]] = [:]
  private(set) var loading: Set<String> = []
  private(set) var errors: [String: String] = [:]
  private(set) var expanded: Set<String> = []
  @ObservationIgnored private var client: (any CodevisorServerClienting)?

  var rows: [Row] {
    guard let root else { return [] }
    var rows: [Row] = []
    func walk(_ directory: String, depth: Int) {
      for entry in listings[directory] ?? [] {
        rows.append(Row(entry: entry, depth: depth))
        if entry.isDirectory, expanded.contains(entry.path) {
          walk(entry.path, depth: depth + 1)
        }
      }
    }
    walk(root, depth: 0)
    return rows
  }

  func show(root: String?, client: any CodevisorServerClienting) async {
    if root != self.root {
      self.root = root
      listings = [:]
      loading = []
      errors = [:]
      expanded = []
    }
    self.client = client
    await refresh()
  }

  func refresh() async {
    guard let root else { return }
    await load(root)
    for directory in expanded where listings[directory] != nil {
      await load(directory)
    }
  }

  func toggle(_ directory: String) async {
    if expanded.remove(directory) == nil {
      expanded.insert(directory)
      if listings[directory] == nil { await load(directory) }
    }
  }

  private func load(_ directory: String) async {
    guard let client, let root, !loading.contains(directory) else { return }
    loading.insert(directory)
    defer { loading.remove(directory) }
    do {
      let entries = try await client.fileEntries(path: directory, showHidden: true).entries
      guard root == self.root else { return }
      listings[directory] = entries.filter { !Self.hiddenNames.contains($0.name) }
      errors[directory] = nil
    } catch {
      guard root == self.root, !Task.isCancelled else { return }
      errors[directory] = error.localizedDescription
    }
  }
}
