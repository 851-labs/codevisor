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
    if let root = model.root, model.listings[root]?.isEmpty == false {
      Form {
        Section {
          WorkspaceInspectorFileTreeRows(model: model, onOpen: onOpen)
        }
      }
      .formStyle(.grouped)
    } else if let rootPhase {
      WorkspaceInspectorMediaPlaceholder(
        phase: rootPhase, emptyTitle: model.root == nil ? "No Folder" : "No Files", systemImage: "folder",
        emptyDescription: model.root == nil
          ? "This workspace doesn't have a folder to browse."
          : "This workspace's folder is empty.",
        onRetry: { Task { await model.refresh() } }
      )
    } else {
      Color.clear
    }
  }
}

private struct WorkspaceInspectorFileTreeRows: View {
  let model: WorkspaceInspectorFileTreeModel
  let onOpen: (WorkspaceInspectorView.Destination) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let disclosureWidth: CGFloat = 11
  private static let disclosureRowInset: CGFloat = 4

  var body: some View {
    ForEach(model.rows) { row in
      let entry = row.entry
      let indent = CGFloat(row.depth) * Self.disclosureWidth
      if entry.isDirectory {
        DisclosureGroup(isExpanded: expansion(entry.path)) {
          EmptyView()
        } label: {
          label(entry)
        }
        .padding(.leading, indent)
      } else {
        Button {
          onOpen(.file(entry.path))
        } label: {
          label(entry)
        }
        .buttonStyle(.plain)
        .padding(.leading, indent + Self.disclosureWidth)
        .padding(.vertical, Self.disclosureRowInset)
      }
    }
  }

  private func expansion(_ path: String) -> Binding<Bool> {
    Binding(
      get: { model.expanded.contains(path) },
      set: { isExpanded in
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
          model.setExpanded(path, isExpanded)
        }
      }
    )
  }

  private func label(_ entry: ServerFileEntry) -> some View {
    WorkspaceInspectorFileTreeLabel(entry: entry, isLoading: model.slow.contains(entry.path))
  }
}

struct WorkspaceInspectorFileTreeLabel: View {
  let entry: ServerFileEntry
  let isLoading: Bool

  var body: some View {
    HStack(spacing: 6) {
      Group {
        if isLoading {
          ProgressView().controlSize(.mini)
        } else {
          FileIcon(path: entry.path, isDirectory: entry.isDirectory, size: 16)
        }
      }
      .frame(width: 16, height: 16)
      Text(entry.name)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .help(entry.path)
    .contextMenu {
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
      }
    }
  }
}
