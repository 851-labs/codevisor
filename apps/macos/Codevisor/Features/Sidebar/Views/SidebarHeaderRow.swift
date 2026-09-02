import SwiftUI

/// Shared geometry for the pinned sidebar items. The development identity
/// row is informational, while action rows add their own hover and tap
/// behavior on top of this label.
struct SidebarHeaderRow: View {
  let title: String
  let systemImage: String
  var foregroundColor: Color? = nil

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .frame(width: 18)
        .foregroundStyle(foregroundColor ?? Color.secondary)
      Text(title)
        .foregroundStyle(foregroundColor ?? Color.primary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
