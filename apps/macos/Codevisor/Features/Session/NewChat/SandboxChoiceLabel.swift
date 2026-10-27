import CodevisorCore
import SwiftUI

struct SandboxChoiceLabel: View {
  let choice: SandboxProfileChoice

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(choice.target.pickerTitle)
      if let reason = choice.disabledReason {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
