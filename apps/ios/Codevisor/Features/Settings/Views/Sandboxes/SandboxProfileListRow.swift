import CodevisorCore
import SwiftUI

struct SandboxProfileListRow: View {
  let profile: ServerSandboxProfile

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: SandboxVendorSymbol.name(for: profile.vendor))
        .foregroundStyle(.secondary)
        .frame(width: 22)
      Text(profile.name)
        .foregroundStyle(.primary)
      Spacer()
      Image(systemName: "chevron.forward")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
  }
}
