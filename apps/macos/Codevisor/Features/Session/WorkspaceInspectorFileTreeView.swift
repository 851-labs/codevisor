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
          WorkspaceInspectorFileTreeFolder(directory: root, depth: 0, model: model, onOpen: onOpen)
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

private struct WorkspaceInspectorFileTreeFolder: View {
  let directory: String
  let depth: Int
  let model: WorkspaceInspectorFileTreeModel
  let onOpen: (WorkspaceInspectorView.Destination) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let disclosureWidth: CGFloat = 11

  private var levelIndent: CGFloat { depth == 0 ? 0 : Self.disclosureWidth }

  var body: some View {
    ForEach(model.listings[directory] ?? []) { entry in
      if entry.isDirectory {
        DisclosureGroup(isExpanded: expansion(entry.path)) {
          WorkspaceInspectorFileTreeFolder(directory: entry.path, depth: depth + 1, model: model, onOpen: onOpen)
        } label: {
          label(entry)
        }
        .padding(.leading, levelIndent)
      } else {
        Button {
          onOpen(.file(entry.path))
        } label: {
          label(entry)
        }
        .buttonStyle(.plain)
        .padding(.leading, levelIndent + Self.disclosureWidth)
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
    HStack(spacing: 6) {
      Group {
        if model.slow.contains(entry.path) {
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
