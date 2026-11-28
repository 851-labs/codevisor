import SwiftUI

public struct CenteredLaunchStack<Content: View>: View {
  private let spacing: CGFloat
  private let content: Content

  public init(spacing: CGFloat = 22, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  public var body: some View {
    VStack(spacing: spacing) { content }
      .padding(.horizontal, 32)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
