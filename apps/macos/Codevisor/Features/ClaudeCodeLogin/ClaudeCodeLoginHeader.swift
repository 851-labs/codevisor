import SwiftUI

struct ClaudeCodeLoginHeader: View {
  let email: String?

  var body: some View {
    VStack(spacing: 10) {
      HarnessIcon(harnessId: "claude-code", size: 30, weight: .medium)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(spacing: 4) {
        Text("Use Your Claude Code Sign-In?")
          .font(.title3.weight(.semibold))
        Text(explanation)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var explanation: String {
    guard let email else { return "Transferring it signs you out of Claude Code on this Mac." }
    return "Transferring \(email) signs you out of Claude Code on this Mac."
  }
}
