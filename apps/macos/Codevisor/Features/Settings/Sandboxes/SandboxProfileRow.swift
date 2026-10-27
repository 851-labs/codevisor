import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxProfileRow: View {
  let profile: ServerSandboxProfile
  let isUntested: Bool
  let hasAccount: Bool
  let onEdit: () -> Void
  let onEditAccount: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: SandboxTarget.systemImage(forProvider: profile.provider))
        .foregroundStyle(.secondary)
        .frame(width: 20)
      Text(profile.name)
      if isUntested {
        SandboxUntestedBadge()
      }
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
    if hasAccount {
      Button("Edit Account…", action: onEditAccount)
    }
    Divider()
    Button("Delete…", role: .destructive, action: onDelete)
  }
}
