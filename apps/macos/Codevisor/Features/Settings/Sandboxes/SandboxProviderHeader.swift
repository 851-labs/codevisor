import CodevisorCore
import SwiftUI

struct SandboxProviderHeader: View {
  let provider: ServerSandboxProviderInfo
  let title: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: provider.platform == "darwin" ? "desktopcomputer" : "shippingbox.fill")
        .font(.system(size: 20))
        .foregroundStyle(.white)
        .frame(width: 40, height: 40)
        .background(Color.teal.gradient, in: .rect(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(title)
            .font(.headline)
          if !provider.tested {
            SandboxUntestedBadge()
          }
        }
        Text(provider.displayName)
          .foregroundStyle(.secondary)
      }
    }
  }
}
