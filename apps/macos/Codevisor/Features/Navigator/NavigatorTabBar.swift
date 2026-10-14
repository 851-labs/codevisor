import CodevisorUI
import SwiftUI

/// Xcode's navigator selector: a glass capsule of icon buttons whose
/// selection slides between them.
struct NavigatorTabBar: View {
  @Environment(\.theme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var selection: NavigatorTab
  /// Counts worth noticing from another tab, like source control's changes.
  var badges: [NavigatorTab: Int] = [:]
  @Namespace private var selectionIndicator

  var body: some View {
    HStack(spacing: 2) {
      ForEach(NavigatorTab.allCases) { tab in
        button(tab)
      }
    }
    .padding(3)
    .background {
      if theme.isSystem {
        Color.clear.glassEffect(.regular, in: Capsule())
      } else {
        Capsule()
          .fill(theme.rowSelectedBackground.opacity(0.5))
          .overlay(Capsule().strokeBorder(theme.border))
      }
    }
  }

  private func button(_ tab: NavigatorTab) -> some View {
    let isSelected = tab == selection
    return Button {
      withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { selection = tab }
    } label: {
      Image(systemName: tab.systemImage)
        .font(.system(size: Typography.IconSize.toolbar, weight: .medium))
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background {
          if isSelected {
            Capsule()
              .fill(
                theme.isSystem ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(theme.rowSelectedBackground)
              )
              .matchedGeometryEffect(id: "selection", in: selectionIndicator)
          }
        }
        .overlay(alignment: .topTrailing) {
          if let count = badges[tab], count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
              .font(.system(size: Typography.IconSize.compact, weight: .semibold).monospacedDigit())
              .foregroundStyle(.white)
              .padding(.horizontal, 4)
              .frame(minWidth: 14, minHeight: 14)
              .background(Capsule().fill(.tint))
              .offset(x: -6, y: -2)
              .accessibilityHidden(true)
          }
        }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(tab.title)
    .accessibilityLabel(tab.title)
    .accessibilityValue(badges[tab].map { $0 > 0 ? "\($0) changes" : "" } ?? "")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
