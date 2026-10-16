import CodevisorClient
import SwiftUI

struct WorkspaceInspectorFileOutlineView: View {
  private struct Node: Identifiable {
    enum Kind {
      case entry(ServerFileEntry)
      case loading(String)
    }

    let id: String
    let kind: Kind
    let children: [Node]?
  }

  let model: WorkspaceInspectorFileTreeModel
  let onOpen: (WorkspaceInspectorView.Destination) -> Void

  var body: some View {
    if let root = model.root, model.listings[root] != nil {
      List(nodes(in: root), children: \.children) { node in
        row(node)
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
    } else if let root = model.root, let error = model.errors[root] {
      WorkspaceInspectorMediaPlaceholder(
        phase: .failed(error), emptyTitle: "No Files", systemImage: "folder", emptyDescription: "",
        onRetry: { Task { await model.refresh() } }
      )
    } else {
      Color.clear
    }
  }

  private func nodes(in directory: String) -> [Node] {
    (model.listings[directory] ?? []).map(node)
  }

  private func node(_ entry: ServerFileEntry) -> Node {
    guard entry.isDirectory else { return Node(id: entry.path, kind: .entry(entry), children: nil) }
    let children =
      model.listings[entry.path] == nil
      ? [Node(id: entry.path + "/\u{0}loading", kind: .loading(entry.path), children: nil)]
      : nodes(in: entry.path)
    return Node(id: entry.path, kind: .entry(entry), children: children)
  }

  @ViewBuilder
  private func row(_ node: Node) -> some View {
    switch node.kind {
    case let .entry(entry):
      if entry.isDirectory {
        WorkspaceInspectorFileTreeLabel(entry: entry, isLoading: model.slow.contains(entry.path))
      } else {
        Button {
          onOpen(.file(entry.path))
        } label: {
          WorkspaceInspectorFileTreeLabel(entry: entry, isLoading: false)
        }
        .buttonStyle(.plain)
      }
    case let .loading(directory):
      Text("Loading…")
        .foregroundStyle(.secondary)
        .task { await model.loadIfNeeded(directory) }
    }
  }
}
