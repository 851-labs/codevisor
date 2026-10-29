import CodevisorCore
import SwiftUI

struct SandboxChoiceLabel: View {
  let choice: SandboxProfileChoice

  var body: some View {
    HStack(spacing: 6) {
      Text(choice.target.profileName)
      Spacer(minLength: 8)
      if choice.availability == .checking {
        ProgressView()
          .controlSize(.mini)
          .accessibilityLabel("Checking")
      } else if case .full = choice.availability {
        Text("Full")
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
