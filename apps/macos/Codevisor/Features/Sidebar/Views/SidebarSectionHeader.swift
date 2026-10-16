import AppKit
import CodevisorUI
import SwiftUI

struct SidebarSectionHeader: View {
  let title: String
  let isExpanded: Bool
  let onToggle: () -> Void
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    let showsChevron = isHovered && controlActiveState == .key
    HStack(spacing: 6) {
      SidebarSectionTitle(title: title)

      Spacer(minLength: 0)

      Button(action: onToggle) {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .animation(Motion.indicator(reduceMotion: reduceMotion)) { chevron in
            chevron.rotationEffect(.degrees(isExpanded ? 90 : 0))
          }
          .frame(width: 16, height: 16)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
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

struct SidebarSectionTitle: NSViewRepresentable {
  let title: String

  func makeNSView(context: Context) -> SidebarSectionTitleLabel {
    let label = SidebarSectionTitleLabel(labelWithString: title)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
    label.applyColor()
    return label
  }

  func updateNSView(_ label: SidebarSectionTitleLabel, context: Context) {
    label.stringValue = title
  }
}

final class SidebarSectionTitleLabel: NSTextField {
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColor()
  }

  func applyColor() {
    let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    textColor = isDark ? .secondaryLabelColor : .tertiaryLabelColor
  }
}
