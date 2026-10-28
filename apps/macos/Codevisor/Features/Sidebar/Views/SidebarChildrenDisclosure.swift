import CodevisorUI
import SwiftUI

struct SidebarChildrenDisclosure: View {
  let disclosure: SidebarRow.Disclosure
  let onToggle: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 3) {
        Text(disclosure.childCount, format: .number)
          .monospacedDigit()
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .animation(Motion.indicator(reduceMotion: reduceMotion)) { chevron in
            chevron.rotationEffect(.degrees(disclosure.isExpanded ? 90 : 0))
          }
      }
      .font(.caption)
      .frame(height: SidebarRowIcon.trailingSlot)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
    .accessibilityLabel(help)
  }

  private var help: String {
    let count = disclosure.childCount
    let noun = count == 1 ? "subagent workspace" : "subagent workspaces"
    return disclosure.isExpanded ? "Hide \(count) \(noun)" : "Show \(count) \(noun)"
  }
}
