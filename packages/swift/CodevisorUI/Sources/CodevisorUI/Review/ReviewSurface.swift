import SwiftUI

enum ReviewSurface {
  static var page: Color {
    #if canImport(AppKit)
      Color(nsColor: .textBackgroundColor)
    #else
      Color(uiColor: .systemBackground)
    #endif
  }
}

extension View {
  func reviewCardHeader(isCollapsed _: Bool) -> some View {
    background { ReviewSurface.page }
      .overlay(alignment: .bottom) { Hairline(color: .separatorColor) }
  }

  func reviewCardBody() -> some View {
    background(.quaternary.opacity(0.4))
      .background(ReviewSurface.page)
      .overlay(alignment: .bottom) { Hairline(color: .separatorColor) }
  }
}
