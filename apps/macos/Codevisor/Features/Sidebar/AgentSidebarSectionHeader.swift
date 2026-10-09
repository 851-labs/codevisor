import SwiftUI

/// A folder (manual grouping) or a project (project grouping): a section
/// title that collapses its agents. Laid out exactly like an agent row --
/// the same insets, an 18pt icon column, and the same gap to the title -- so
/// its icon and title line up with the rows under and around it.
struct AgentSidebarSectionHeader: View {
  let title: String
  let systemImage: String
  let isCollapsed: Bool
  let onToggle: () -> Void

  /// How far a folder's agents, and an agent's own agents, sit in.
  static let indent: CGFloat = 16

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 7) {
        Image(systemName: systemImage)
          // The harness icons beside it are 13pt artwork.
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(width: 18)
        Text(title).fontWeight(.semibold).lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
      }
      .padding(.vertical, 5)
      .padding(.horizontal, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title), \(isCollapsed ? "collapsed" : "expanded")")
  }
}
