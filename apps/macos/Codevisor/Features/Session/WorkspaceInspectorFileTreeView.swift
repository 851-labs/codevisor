import AppKit
import CodevisorClient
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorFileTreeView: View {
  let model: WorkspaceInspectorFileTreeModel
  let onOpen: (WorkspaceInspectorView.Destination) -> Void

  private var rootPhase: WorkspaceInspectorMediaModel.Phase? {
    guard let root = model.root else { return .loaded }
    if let error = model.errors[root] { return .failed(error) }
    if model.listings[root] != nil { return .loaded }
    return model.slow.contains(root) ? .loading : nil
  }

  var body: some View {
    let rows = model.rows
    if rows.isEmpty, rootPhase == nil {
      Color.clear
    } else if rows.isEmpty, let rootPhase {
      WorkspaceInspectorMediaPlaceholder(
        phase: rootPhase, emptyTitle: model.root == nil ? "No Folder" : "No Files", systemImage: "folder",
        emptyDescription: model.root == nil
          ? "This workspace doesn't have a folder to browse."
          : "This workspace's folder is empty.",
        onRetry: { Task { await model.refresh() } }
      )
    } else {
      Form {
        Section {
          ForEach(rows) { row in
            self.row(row)
          }
        }
      }
      .formStyle(.grouped)
    }
  }

  private func row(_ row: WorkspaceInspectorFileTreeModel.Row) -> some View {
    let entry = row.entry
    let isExpanded = model.expanded.contains(entry.path)
    return Button {
      if entry.isDirectory {
        Task { await model.toggle(entry.path) }
      } else {
        onOpen(.file(entry.path))
      }
    } label: {
      HStack(spacing: 4) {
        Group {
          if model.slow.contains(entry.path) {
            ProgressView().controlSize(.mini)
          } else {
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
              .opacity(entry.isDirectory ? 1 : 0)
          }
        }
        .frame(width: 12)
        FileIcon(path: entry.path, isDirectory: entry.isDirectory, size: 16)
        Text(entry.name)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .padding(.leading, CGFloat(row.depth) * 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(entry.path)
    .accessibilityAddTraits(entry.isDirectory ? [] : .isLink)
    .accessibilityValue(entry.isDirectory ? (isExpanded ? "Expanded" : "Collapsed") : "")
    .contextMenu {
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
      }
    }
  }
}
