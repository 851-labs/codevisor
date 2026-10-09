import SwiftUI

/// A folder (manual grouping) or a project (project grouping): a section
/// title that collapses its agents.
struct AgentSidebarSectionHeader: View {
  let title: String
  let systemImage: String
  let isCollapsed: Bool
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 6) {
        Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
        Text(title).fontWeight(.semibold).lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
      }
      .font(.callout)
      .padding(.vertical, 5)
      .padding(.horizontal, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title), \(isCollapsed ? "collapsed" : "expanded")")
  }
}
