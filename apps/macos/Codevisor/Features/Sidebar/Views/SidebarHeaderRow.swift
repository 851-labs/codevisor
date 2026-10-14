import SwiftUI

/// Shared geometry for the pinned sidebar items. The development identity
/// row is informational, while action rows add their own hover and tap
/// behavior on top of this label.
struct SidebarHeaderRow: View {
  let title: String
  let systemImage: String
  var foregroundColor: Color? = nil
  /// The title's style when no `foregroundColor` overrides it.
  var titleStyle: HierarchicalShapeStyle = .primary

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .frame(width: 18)
        // Hierarchical styles, not `Color.secondary`/`Color.primary`: only
        // they take the sidebar's vibrancy, so the icon matches the rows'.
        .foregroundStyle(foregroundColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
      Text(title)
        .foregroundStyle(foregroundColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(titleStyle))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
