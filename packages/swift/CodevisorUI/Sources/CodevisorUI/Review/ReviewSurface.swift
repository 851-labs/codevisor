import SwiftUI

struct ReviewSurface {
  let theme: Theme

  var page: Color {
    guard theme.isSystem else { return theme.windowBackground }
    #if canImport(AppKit)
      return Color(nsColor: .textBackgroundColor)
    #else
      return Color(uiColor: .systemBackground)
    #endif
  }

  @ViewBuilder
  var headerFill: some View {
    ZStack {
      page
      if !theme.isSystem {
        theme.cardBackgroundColor
      }
    }
  }
}

extension View {
  func reviewCardHeader(isCollapsed _: Bool, theme: Theme) -> some View {
    background { ReviewSurface(theme: theme).headerFill }
      .overlay(alignment: .bottom) { Hairline(color: theme.border) }
  }

  func reviewCardBody(theme: Theme) -> some View {
    background(theme.codeBackground)
      .background(ReviewSurface(theme: theme).page)
      .overlay(alignment: .bottom) { Hairline(color: theme.border) }
  }
}
