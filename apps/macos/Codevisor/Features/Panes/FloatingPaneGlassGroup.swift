import SwiftUI

struct FloatingPaneGlassGroup<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 0) { content() }
      .padding(.horizontal, 2)
      .buttonStyle(FloatingPaneGlassButtonStyle())
      .menuStyle(.button)
      .foregroundStyle(.primary)
      .glassEffect(.regular.interactive(), in: .capsule)
  }
}

struct FloatingPaneGlassButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Cell(configuration: configuration)
  }

  private struct Cell: View {
    private static let side: CGFloat = 28

    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
      configuration.label
        .padding(.horizontal, 6)
        .frame(minWidth: Self.side, minHeight: Self.side)
        .contentShape(.capsule)
        .background(.primary.opacity(highlight), in: .capsule)
        .onHover { hovering = $0 }
    }

    private var highlight: Double {
      if configuration.isPressed { return 0.16 }
      return hovering ? 0.08 : 0
    }
  }
}
