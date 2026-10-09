import SwiftUI

/// A folder (manual grouping) or a project (project grouping): a section
/// title that collapses its agents. Laid out, set and highlighted exactly
/// like an agent row -- the same insets, an 18pt icon column, the same gap
/// and font, the same hover -- so it reads as one of the list's rows; its
/// icon and chevron say it's a folder. Clicking it only turns the chevron
/// and opens or closes the folder.
struct AgentSidebarSectionHeader: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let title: String
  let systemImage: String
  let isCollapsed: Bool
  let onToggle: () -> Void

  /// How far a folder's agents, and an agent's own agents, sit in.
  static let indent: CGFloat = 16

  var body: some View {
    HoverableRow { _ in
      HStack(spacing: 7) {
        Image(systemName: systemImage)
          // The harness icons beside it are 13pt artwork.
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(width: 18)
        Text(title).lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
          .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isCollapsed)
      }
      .padding(.vertical, 5)
      .padding(.horizontal, 8)
      .contentShape(Rectangle())
      .onTapGesture(perform: onToggle)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(isCollapsed ? "collapsed" : "expanded")")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { onToggle() }
  }
}
