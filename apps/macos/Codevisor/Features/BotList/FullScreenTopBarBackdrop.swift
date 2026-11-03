import SwiftUI

struct FullScreenTopBarBackdrop: View {
  private static let fadeDuration: TimeInterval = 0.2

  let isVisible: Bool
  let height: CGFloat

  var body: some View {
    Rectangle()
      .fill(.bar)
      .frame(height: height)
      .opacity(isVisible ? 1 : 0)
      .animation(.easeInOut(duration: Self.fadeDuration), value: isVisible)
      .allowsHitTesting(false)
  }
}
