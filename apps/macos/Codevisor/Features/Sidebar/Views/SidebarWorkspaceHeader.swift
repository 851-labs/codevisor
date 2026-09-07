import SwiftUI

/// A compact section heading above a workspace's always-visible tabs.
struct SidebarWorkspaceHeader: View {
  let name: String
  /// Only remote workspaces include their machine's name.
  let machineName: String?
  let isReordering: Bool
  let onArchive: () -> Void
  let onRename: () -> Void
  let onNewTab: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 6) {
      HStack(spacing: 6) {
        Text(title)
          .truncationMode(.middle)
        if let machineName {
          Text("· \(machineName)")
            .foregroundStyle(.tertiary)
        }
      }
      .font(.subheadline.weight(.semibold))
      .lineLimit(1)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      .help(machineName.map { "\(title) · \($0)" } ?? title)

      Spacer(minLength: 0)

      if isHovered && !isReordering {
        Button(action: onArchive) {
          Image(systemName: "archivebox")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .help("Archive workspace")
        .accessibilityLabel("Archive \(title)")
        .frame(width: 24, height: 14, alignment: .trailing)
      }
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.top, 12)
    .padding(.bottom, 4)
    .contentShape(Rectangle())
    .hoverTracking($isHovered)
    .contextMenu {
      Button(action: onNewTab) {
        Label("New Tab", systemImage: "plus")
          .labelStyle(.titleAndIcon)
      }
      Divider()
      Button(action: onRename) {
        Label("Rename", systemImage: "pencil")
          .labelStyle(.titleAndIcon)
      }
      Button(action: onArchive) {
        Label("Archive", systemImage: "archivebox")
          .labelStyle(.titleAndIcon)
      }
    }
  }

  private var title: String {
    name.isEmpty ? "Workspace" : name
  }
}
