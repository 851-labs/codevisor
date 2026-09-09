import SwiftUI

/// A workspace's section header, above its card of tabs: one line of
/// `name · machine` (the name always fits; the machine yields and truncates)
/// and a menu of workspace actions. Long-pressing the header lifts the
/// workspace to reorder it (see `HomeSidebarList`).
struct HomeSidebarSectionHeader: View {
  let section: HomeSidebarSection
  /// While a workspace is lifted the list is just names: the menu leaves
  /// the row entirely, so the name and machine get its width back.
  var isReordering = false
  let onNewTab: () -> Void
  let onRename: () -> Void
  let onArchive: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      // HIG: hierarchy by weight and color, not a third size — the name is
      // `.headline` (17 semibold), the machine `.body` (17 regular) in
      // secondary color on the same baseline.
      Text(section.displayName)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .layoutPriority(1)
      if let machineName = section.machineName {
        Text("· \(machineName)")
          .font(.body)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: isReordering ? 0 : 8)
      if !isReordering {
        menu
      }
    }
    .textCase(nil)
    .accessibilityElement(children: .contain)
  }

  private var menu: some View {
    Group {
      Menu {
        Button(action: onNewTab) {
          Label("New Tab", systemImage: "plus")
        }
        Divider()
        Button(action: onRename) {
          Label("Rename", systemImage: "pencil")
        }
        Button(action: onArchive) {
          Label("Archive", systemImage: "archivebox")
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.body.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("\(section.displayName) actions")
    }
  }
}
