import SwiftUI

struct SidebarScrollFade: Equatable {
  static let overhang: CGFloat = 10
  static let edgeOpacity = 0.15

  var top: CGFloat = 0
  var bottom: CGFloat = 0
}

struct SidebarScrollFadeMask: View {
  let fade: SidebarScrollFade

  var body: some View {
    VStack(spacing: 0) {
      edge(under: fade.top, startPoint: .top, endPoint: .bottom)
      Color.black
      edge(under: fade.bottom, startPoint: .bottom, endPoint: .top)
    }
  }

  private func edge(under bar: CGFloat, startPoint: UnitPoint, endPoint: UnitPoint) -> some View {
    let height = bar + SidebarScrollFade.overhang
    return LinearGradient(
      stops: [
        .init(color: .clear, location: 0),
        .init(color: .black.opacity(SidebarScrollFade.edgeOpacity), location: bar / height),
        .init(color: .black, location: 1),
      ],
      startPoint: startPoint, endPoint: endPoint
    )
    .frame(height: height)
  }
}
