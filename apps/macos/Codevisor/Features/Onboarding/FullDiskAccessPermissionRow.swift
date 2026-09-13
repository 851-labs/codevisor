import AppKit
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

/// macOS has no supported Full Disk Access status API or consent prompt.
/// Open Settings without claiming a grant on return.
struct FullDiskAccessPermissionRow: View {
  @Environment(\.theme) private var theme

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "internaldrive")
        .font(.system(size: 18, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.secondary)
        .frame(width: 34, height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardHoverBackground))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("Full Disk Access")
          .fontWeight(.medium)
        Text("Accesses protected files")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button("Open Settings…") {
        guard let url = SystemSettingsPane.fullDiskAccess.url else { return }
        NSWorkspace.shared.open(url)
      }
      .accessibilityLabel("Open Full Disk Access settings")
    }
    .padding(.vertical, 10)
  }
}
