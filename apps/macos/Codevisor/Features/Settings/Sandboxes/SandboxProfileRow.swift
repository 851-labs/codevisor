import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxProfileRow: View {
  let profile: ServerSandboxProfile

  var body: some View {
    HStack(spacing: 10) {
      CodevisorSymbol.sandboxVendor(profile.vendor)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      Text(profile.name)
    }
  }
}
