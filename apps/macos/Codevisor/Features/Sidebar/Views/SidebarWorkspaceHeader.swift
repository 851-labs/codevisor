import SwiftUI

struct SidebarWorkspaceHeader: View {
  let name: String
  let machineName: String?
  let isReordering: Bool
  let onArchive: () -> Void
  let onRename: () -> Void
  let onNewTab: () -> Void

  @State private var isHovered = false

  static let horizontalPadding: CGFloat = 12
  static let topPadding: CGFloat = 12
  static let bottomPadding: CGFloat = 4

  var body: some View {
    HStack(spacing: 6) {
      SidebarWorkspaceHeaderLabel(name: name, machineName: machineName)

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
        .accessibilityHidden(true)
      }
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, Self.horizontalPadding)
    .padding(.top, Self.topPadding)
    .padding(.bottom, Self.bottomPadding)
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
      .shortcut(.archiveWorkspace)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
    .accessibilityActions {
      Button("New Tab", action: onNewTab)
      Button("Rename", action: onRename)
      Button("Archive", action: onArchive)
    }
  }

  private var title: String {
    SidebarWorkspaceHeaderLabel.title(for: name)
  }
}

struct SidebarWorkspaceHeaderLabel: View {
  let name: String
  let machineName: String?

  static func title(for name: String) -> String {
    name.isEmpty ? "Workspace" : name
  }

  private var title: String { Self.title(for: name) }

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
      if let machineName {
        Text("·")
          .foregroundStyle(.tertiary)
        Text(machineName)
          .foregroundStyle(.tertiary)
      }
    }
    .font(.subheadline.weight(.semibold))
    .lineLimit(1)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
    .help(machineName.map { "\(title) · \($0)" } ?? title)
  }
}
