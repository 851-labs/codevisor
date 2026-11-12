import SwiftUI

struct MachineDesktopFailure: View {
  let message: String
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "display.trianglebadge.exclamationmark")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button("Retry", action: onRetry)
        .controlSize(.small)
    }
    .padding(16)
  }
}
