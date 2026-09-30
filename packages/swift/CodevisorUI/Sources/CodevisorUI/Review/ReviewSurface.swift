import SwiftUI

/// Colors for the Review pane's files. Each file is a full-width band, like
/// an editor rather than a web page: a header on an opaque surface, a
/// hairline, then the code on the editor surface its syntax colors were
/// designed for, and a hairline closing the file.
///
/// The page is always opaque and painted explicitly, so a pinned header
/// hides the diff scrolling beneath it.
struct ReviewSurface {
  let theme: Theme

  /// System themes use the platform's content background (white/black text
  /// surfaces); custom themes paint their window color.
  var page: Color {
    guard theme.isSystem else { return theme.windowBackground }
    #if canImport(AppKit)
      return Color(nsColor: .textBackgroundColor)
    #else
      return Color(uiColor: .systemBackground)
    #endif
  }

  /// Distinct from the code: on system themes the code sits on a tinted
  /// fill, so the header takes the page color; custom themes paint code on
  /// the window color, so the header takes the theme's card color.
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

/// A one-device-pixel rule in the theme's border color.
private struct ReviewHairline: View {
  let theme: Theme
  @Environment(\.pixelLength) private var pixelLength

  var body: some View {
    theme.border.frame(height: pixelLength)
  }
}

extension View {
  /// A file header: a flat band whose bottom hairline divides it from the
  /// code (or from the next file, while folded).
  func reviewCardHeader(isCollapsed _: Bool, theme: Theme) -> some View {
    background { ReviewSurface(theme: theme).headerFill }
      .overlay(alignment: .bottom) { ReviewHairline(theme: theme) }
  }

  /// A file's diff below its header, closed by a hairline.
  func reviewCardBody(theme: Theme) -> some View {
    background(theme.codeBackground)
      .background(ReviewSurface(theme: theme).page)
      .overlay(alignment: .bottom) { ReviewHairline(theme: theme) }
  }
}
