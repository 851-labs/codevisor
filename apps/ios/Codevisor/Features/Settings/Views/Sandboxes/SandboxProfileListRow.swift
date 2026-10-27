import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxProfileListRow: View {
  let profile: ServerSandboxProfile
  let isUntested: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: SandboxTarget.systemImage(forProvider: profile.provider))
        .foregroundStyle(.secondary)
        .frame(width: 22)
      Text(profile.name)
        .foregroundStyle(.primary)
      if isUntested {
        SandboxUntestedBadge()
      }
      Spacer()
      Image(systemName: "chevron.forward")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
  }
}
