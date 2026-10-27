import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxProfileRow: View {
  let profile: ServerSandboxProfile
  let hasProvider: Bool
  let onEdit: () -> Void
  let onEditProvider: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      CodevisorSymbol.sandboxVendor(profile.vendor)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      Text(profile.name)
      Spacer()
      Menu {
        actions
      } label: {
        Image(systemName: "ellipsis.circle")
          .foregroundStyle(.secondary)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Profile actions")
      .accessibilityLabel("Actions for \(profile.name)")
    }
    .contextMenu { actions }
  }

  @ViewBuilder
  private var actions: some View {
    Button("Edit…", action: onEdit)
    if hasProvider {
      Button("Edit Provider…", action: onEditProvider)
    }
    Divider()
    Button("Delete…", role: .destructive, action: onDelete)
  }
}
