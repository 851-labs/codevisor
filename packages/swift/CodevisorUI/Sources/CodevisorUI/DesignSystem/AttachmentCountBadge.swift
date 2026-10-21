import SwiftUI

public struct AttachmentCountBadge: View {
  let count: Int

  public init(count: Int) {
    self.count = count
  }

  public var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "paperclip")
      Text(count, format: .number)
        .monospacedDigit()
    }
    .font(.footnote.weight(.semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .scaledFrame(height: ComposerCardStyle.actionDiameter, relativeTo: .footnote)
    .background(Capsule().fill(Color.secondary.opacity(0.16)))
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(count == 1 ? "1 attachment" : "\(count) attachments")
  }
}
