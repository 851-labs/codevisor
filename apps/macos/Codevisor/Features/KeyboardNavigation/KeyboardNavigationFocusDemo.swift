import CodevisorUI
import SwiftUI

struct KeyboardNavigationFocusDemo: View {
  private static let controlCount = 3
  private static let step: Duration = .seconds(0.9)

  @State private var focused = 0

  var body: some View {
    HStack(spacing: 16) {
      KeyboardNavigationKeycap()
      Image(systemName: "chevron.right")
        .foregroundStyle(.tertiary)
      HStack(spacing: 8) {
        ForEach(0..<Self.controlCount, id: \.self) { index in
          FakeControl(isFocused: index == focused)
        }
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity)
    .background(RoundedRectangle(cornerRadius: 14).fill(Color.cardBackgroundColor))
    .accessibilityHidden(true)
    .task { await cycleFocus() }
  }

  private func cycleFocus() async {
    while !Task.isCancelled {
      try? await Task.sleep(for: Self.step)
      withAnimation(.snappy(duration: 0.25)) { focused = (focused + 1) % Self.controlCount }
    }
  }
}

private struct FakeControl: View {
  let isFocused: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 7, style: .continuous)
      .fill(.quaternary)
      .frame(width: 44, height: 26)
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Color.accentColor, lineWidth: 3)
          .padding(-4)
          .opacity(isFocused ? 1 : 0)
      )
  }
}
