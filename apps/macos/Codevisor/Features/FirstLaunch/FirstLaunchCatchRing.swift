import SwiftUI

struct FirstLaunchCatchRing: View {
  let isCaught: Bool
  let cornerRadius: CGFloat
  @State private var isLit = false

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius)
      .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
      .shadow(color: Color.accentColor.opacity(0.35), radius: 8)
      .scaleEffect(isLit ? 1.025 : 1)
      .opacity(isLit ? 1 : 0)
      .allowsHitTesting(false)
      .onChange(of: isCaught) { _, caught in
        guard caught else { return }
        withAnimation(.easeOut(duration: 0.1).delay(0.4)) {
          isLit = true
        } completion: {
          withAnimation(.easeIn(duration: 0.2)) { isLit = false }
        }
      }
  }
}
