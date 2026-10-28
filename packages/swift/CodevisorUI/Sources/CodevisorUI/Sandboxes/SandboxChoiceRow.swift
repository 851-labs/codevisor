import SwiftUI

public struct SandboxChoiceRow: View {
  let icon: Image
  let title: String
  var detail: String?
  let action: () -> Void

  public init(icon: Image, title: String, detail: String? = nil, action: @escaping () -> Void) {
    self.icon = icon
    self.title = title
    self.detail = detail
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        icon
          .font(.title3)
          .foregroundStyle(.secondary)
          .frame(width: 24)
        Text(title)
          .foregroundStyle(.primary)
        Spacer()
        if let detail {
          Text(detail)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Image(systemName: "chevron.forward")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }
}
