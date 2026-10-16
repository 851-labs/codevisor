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
  private static let slowDelay = Duration.milliseconds(800)

  private(set) var root: String?
  private(set) var listings: [String: [ServerFileEntry]] = [:]
  private(set) var errors: [String: String] = [:]
  private(set) var expanded: Set<String> = []
  private(set) var slow: Set<String> = []
  @ObservationIgnored private var loading: Set<String> = []
  @ObservationIgnored private var stale: Set<String> = []
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
      errors = [:]
      expanded = []
      slow = []
      loading = []
      stale = []
    }
    self.client = client
    await refresh()
  }

  func refresh() async {
    guard let root else { return }
    stale = Set(listings.keys).subtracting(expanded).subtracting([root])
    await load(root)
    for directory in expanded where listings[directory] != nil {
      await load(directory)
    }
  }

  func setExpanded(_ directory: String, _ isExpanded: Bool) {
    guard isExpanded else {
      expanded.remove(directory)
      return
    }
    expanded.insert(directory)
    if listings[directory] == nil || stale.contains(directory) {
      Task { await load(directory) }
    }
  }

  private func load(_ directory: String) async {
    var next = await fetch(directory)
    while let child = next, listings[child] == nil {
      next = await fetch(child)
    }
  }

  private func fetch(_ directory: String) async -> String? {
    guard let client, let root, !loading.contains(directory) else { return nil }
    loading.insert(directory)
    stale.remove(directory)
    let timer = Task {
      try await Task.sleep(for: Self.slowDelay)
      slow.insert(directory)
    }
    defer {
      timer.cancel()
      loading.remove(directory)
      slow.remove(directory)
    }
    do {
      let entries = try await client.fileEntries(path: directory, showHidden: true).entries
        .filter { !Self.hiddenNames.contains($0.name) }
      guard root == self.root else { return nil }
      listings[directory] = entries
      errors[directory] = nil
      guard entries.count == 1, let only = entries.first, only.isDirectory else { return nil }
      return only.path
    } catch {
      guard root == self.root, !Task.isCancelled else { return nil }
      errors[directory] = error.localizedDescription
      if directory != root { expanded.remove(directory) }
      return nil
    }
  }
}
