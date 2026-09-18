import SwiftUI

/// A compact section heading above a workspace's always-visible tabs.
struct SidebarWorkspaceHeader: View {
  let name: String
  /// Where the workspace lives: a remote machine's name, or "This Mac" for
  /// local ones. Nil only when the workspace's machine is unknown.
  let machineName: String?
  let isReordering: Bool
  let onArchive: () -> Void
  let onRename: () -> Void
  let onNewTab: () -> Void

  @State private var isHovered = false

  /// Insets around the label. The reorder ghost reuses these so it can
  /// land pixel-for-pixel on the row it was lifted from.
  static let horizontalPadding: CGFloat = 10
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
    }
  }

  private var title: String {
    SidebarWorkspaceHeaderLabel.title(for: name)
  }
}

/// The header's name (and machine) text, shared with the reorder ghost so
/// the lifted row and its stand-in never drift apart in style.
struct SidebarWorkspaceHeaderLabel: View {
  let name: String
  let machineName: String?

  static func title(for name: String) -> String {
    name.isEmpty ? "Workspace" : name
  }

  private var title: String { Self.title(for: name) }

  var body: some View {
    // 4pt + the glyphs' side bearings lands at ~6pt of visible gap on
    // each side of the dot.
    HStack(spacing: 4) {
      Text(title)
        .truncationMode(.middle)
      if let machineName {
        // Separate view so the dot gets the same spacing on both sides;
        // inside the string it only had a ~3pt space on the right.
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
