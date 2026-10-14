import AppKit
import CodevisorTheming
import CodevisorUI
import SwiftUI

/// A collapsible heading above a run of sidebar rows, as in Mail: the
/// title, then a disclosure chevron at the trailing edge that appears on
/// hover. Clicking anywhere on the heading toggles it.
struct SidebarSectionHeader: View {
  let title: String
  let isExpanded: Bool
  let onToggle: () -> Void
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    // An inactive window spends its first click becoming key, so the
    // chevron only shows once it can respond.
    let showsChevron = isHovered && controlActiveState == .key
    HStack(spacing: 6) {
      SidebarSectionTitle(title: title)

      Spacer(minLength: 0)

      Button(action: onToggle) {
        // Mail's heading chevron: 11pt semibold (measured, pixel for pixel).
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .animation(Motion.indicator(reduceMotion: reduceMotion)) { chevron in
            chevron.rotationEffect(.degrees(isExpanded ? 90 : 0))
          }
          .frame(width: 16, height: 16)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      // Cleared rather than removed or faded out, so the heading holds still
      // and assistive tech can still collapse the section
      // (SwiftUI hides fully transparent views from accessibility).
      .foregroundStyle(showsChevron ? AnyShapeStyle(.secondary) : AnyShapeStyle(.clear))
      .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
      .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.top, 12)
    .padding(.bottom, 4)
    .contentShape(Rectangle())
    .onTapGesture(perform: onToggle)
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .contain)
  }
}

/// A section heading's title, drawn by AppKit: 11pt semibold (Mail's
/// "Favorites") in the tertiary label color, which the sidebar's vibrancy
/// renders exactly as native headings (see `SidebarVibrancyHost`).
///
/// AppKit rather than `Text`: at this size SwiftUI rasterizes semibold with
/// thinner strokes than AppKit (about 10% less ink, measured with the same
/// font), while an `NSTextField` here is pixel-identical to Mail's.
/// Custom themes use their own tertiary text.
struct SidebarSectionTitle: NSViewRepresentable {
  @Environment(\.theme) private var theme
  let title: String

  func makeNSView(context: Context) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    // A heading to assistive tech, as SwiftUI's `.isHeader` trait reported.
    label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
    return label
  }

  func updateNSView(_ label: NSTextField, context: Context) {
    label.stringValue = title
    label.textColor = theme.palette.map { NSColor(rgba: $0.textTertiary) } ?? .tertiaryLabelColor
  }
}
