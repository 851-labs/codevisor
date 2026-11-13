import SwiftUI

public struct IconAnchoredStack<Content: View>: View {
  private let spacing: CGFloat
  private let content: Content

  public init(spacing: CGFloat = 22, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  public var body: some View {
    GeometryReader { area in
      VStack(spacing: spacing) { content }
        .frame(maxWidth: .infinity)
        .padding(.top, (area.size.height * Self.topFraction).rounded())
        .padding(.horizontal, 32)
    }
  }

  private static var topFraction: CGFloat { 0.24 }
}
