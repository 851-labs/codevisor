#if os(iOS)
  import SwiftUI

  public struct SandboxProviderTitleRow: View {
    public static let height: CGFloat = 24

    let icon: Image
    let title: String
    let onEdit: () -> Void
    let onDelete: () -> Void

    public var body: some View {
      HStack(spacing: 6) {
        icon
        Text(title)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .font(.body.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
      .contextMenu {
        Button("Edit", systemImage: "pencil", action: onEdit)
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
      }
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 0, trailing: 20))
      .accessibilityAddTraits(.isHeader)
    }
  }
#endif
