import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorSourceControlView: View {
  let model: WorkspaceInspectorMediaModel
  let onOpen: (WorkspaceInspectorView.Destination) -> Void
  let onRetry: () -> Void

  var body: some View {
    if model.changes.isEmpty {
      WorkspaceInspectorMediaPlaceholder(
        phase: model.changesPhase, emptyTitle: "No Changes", systemImage: "arrow.triangle.branch",
        emptyDescription: "Uncommitted changes in this workspace's checkout appear here.",
        onRetry: onRetry
      )
    } else {
      Form {
        Section {
          ForEach(model.changes) { file in
            row(file)
          }
          if case let .failed(message) = model.changesPhase {
            HStack {
              Text("Couldn't refresh changes: \(message)")
                .foregroundStyle(.secondary)
                .lineLimit(2)
              Spacer()
              Button("Try Again", action: onRetry)
            }
          }
        } footer: {
          if model.changesTruncated {
            Text("Showing the first 300 uncommitted changes.")
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
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
        if file.uncommitted, let status = file.status {
          Text(status.letter)
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(statusColor(status))
            .help(status.description)
            .accessibilityLabel(status.description)
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

  private func statusColor(_ status: ServerWorkspaceFileChange.Status) -> Color {
    switch status {
    case .added: .green
    case .modified: .orange
    case .deleted: .red
    }
  }
}

extension ServerWorkspaceFileChange.Status {
  fileprivate var letter: String {
    switch self {
    case .added: "A"
    case .modified: "M"
    case .deleted: "D"
    }
  }

  fileprivate var description: String {
    switch self {
    case .added: "Added, uncommitted"
    case .modified: "Modified, uncommitted"
    case .deleted: "Deleted, uncommitted"
    }
  }
}
