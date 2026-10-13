import AppKit
import CodevisorUI
import SwiftUI

/// A compact heading above a run of sidebar rows, with a trailing control.
struct SidebarSectionHeader<Accessory: View>: View {
  @Environment(\.theme) private var theme
  let title: String
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(SidebarSectionHeaderStyle.color(theme))
        .lineLimit(1)
        .accessibilityAddTraits(.isHeader)

      Spacer(minLength: 0)

      accessory()
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.top, 12)
    .padding(.bottom, 4)
  }
}

/// A native sidebar section header's look: 11pt semibold (identical to
/// Mail's "Favorites", measured) in the color a vibrant sidebar gives
/// `tertiaryLabelColor`. AppKit's vibrancy doesn't reach SwiftUI text, which
/// renders that color lighter, so light mode uses the measured result
/// directly: Mail's header ink is 73% of the sidebar's luminance, i.e. black
/// at 27%. Custom themes use their own tertiary text.
enum SidebarSectionHeaderStyle {
  static func color(_ theme: Theme) -> Color {
    theme.isSystem ? Color(nsColor: systemColor) : theme.textTertiary
  }

  private static let systemColor = NSColor(name: "sidebarSectionHeader") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? .tertiaryLabelColor
      : NSColor.black.withAlphaComponent(0.27)
  }
}
