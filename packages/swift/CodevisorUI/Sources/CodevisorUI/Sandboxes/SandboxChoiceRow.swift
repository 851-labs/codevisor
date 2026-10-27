import SwiftUI

struct SandboxChoiceRow: View {
  let title: String
  let systemImage: String
  var isUntested = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 20)
        Text(title)
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
    .buttonStyle(.plain)
  }
}
