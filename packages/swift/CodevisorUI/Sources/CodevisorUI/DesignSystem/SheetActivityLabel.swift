import SwiftUI

public struct SheetActivityLabel: View {
  @Environment(\.theme) private var theme
  private let title: String

  public init(_ title: String = "Waiting for sign-in…") {
    self.title = title
  }

  public var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
        .tint(theme.isSystem ? nil : theme.accent)
      Text(title)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}
