import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorFilesView: View {
  let model: WorkspaceInspectorMediaModel
  let onOpen: (WorkspaceInspectorView.Destination) -> Void
  let onRetry: () -> Void

  @Environment(\.theme) private var theme

  var body: some View {
    if model.files.isEmpty {
      WorkspaceInspectorMediaPlaceholder(
        phase: model.filesPhase, emptyTitle: "No Files", systemImage: "doc.on.doc",
        emptyDescription: "Files this workspace's agents change, and uncommitted changes in its checkout, appear here.",
        onRetry: onRetry
      )
    } else {
      Form {
        Section {
          ForEach(model.files) { file in
            row(file)
          }
          if case let .failed(message) = model.filesPhase {
            HStack {
              Text("Couldn't refresh files: \(message)")
                .foregroundStyle(.secondary)
                .lineLimit(2)
              Spacer()
              Button("Try Again", action: onRetry)
            }
          }
        } footer: {
          if model.filesTruncated {
            Text("Showing the first 300 uncommitted changes.")
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
    }
  }

  private func row(_ file: ServerWorkspaceFileChange) -> some View {
    let isDeleted = file.status == .deleted
    let path = file.path as NSString
    let directory = path.deletingLastPathComponent
    return Button {
      onOpen(.file(file.path))
    } label: {
      HStack(spacing: 8) {
        FileIcon(path: file.path, size: 16)
        VStack(alignment: .leading, spacing: 1) {
          Text(path.lastPathComponent)
            .strikethrough(isDeleted)
            .lineLimit(1)
            .truncationMode(.middle)
          if !directory.isEmpty {
            Text(directory)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
        Spacer(minLength: 4)
        if file.uncommitted {
          Circle()
            .fill(.tint)
            .frame(width: 6, height: 6)
            .help("Uncommitted")
            .accessibilityLabel("Uncommitted")
        }
        DiffCounter(totals: LineDiff.Totals(added: file.added, removed: file.removed))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDeleted)
    .help(isDeleted ? "\(file.path) was deleted" : file.path)
    .contextMenu {
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
      }
    }
  }
}
