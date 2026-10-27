import CodevisorCore
import SwiftUI

struct SandboxProviderRow: View {
  let title: String
  let vendor: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: SandboxVendorSymbol.name(for: vendor))
          .foregroundStyle(.secondary)
          .frame(width: 20)
        Text(title)
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "chevron.forward")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
