import SwiftUI

struct SidebarHeaderRow: View {
  let title: String
  let systemImage: String
  var foregroundColor: Color? = nil
  var titleStyle: HierarchicalShapeStyle = .primary

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .frame(width: 18)
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
