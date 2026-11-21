import SwiftUI

struct SidebarInsertionLine: View {
  static let height: CGFloat = 7

  var body: some View {
    HStack(spacing: 0) {
      Circle()
        .strokeBorder(Color.accentColor, lineWidth: 2)
        .frame(width: Self.height, height: Self.height)
      Rectangle()
        .fill(Color.accentColor)
        .frame(height: 2)
    }
  }
}

struct SidebarPlacedInsertionLine: View {
  let frame: CGRect

  var body: some View {
    SidebarInsertionLine()
      .frame(width: frame.width, height: SidebarInsertionLine.height)
      .position(x: frame.midX, y: frame.minY)
  }
}
