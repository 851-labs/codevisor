import CodevisorCore
import CodevisorUI
import SwiftUI

/// The folder that gathers chats started without a project. Styled like a
/// project row so the by-project list reads as one hierarchy, minus the
/// affordances that need a repository (new chat here, archive).
struct SidebarNoProjectRow: View {
  let isReordering: Bool
  let isVisuallyExpanded: Bool
  let titleFont: Font
  let onDisclosureToggle: () -> Void

  var body: some View {
    HoverableRow(isHoverEnabled: !isReordering) { isHovered in
      Button(action: onDisclosureToggle) {
        HStack(spacing: 6) {
          // On hover the folder icon becomes a disclosure chevron.
          ZStack {
            Image(systemName: EntitySystemSymbol.projectList)
              .foregroundStyle(.secondary)
              .opacity(isHovered ? 0 : 1)
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(isVisuallyExpanded ? 90 : 0))
              .opacity(isHovered ? 1 : 0)
          }
          .frame(width: 18)
          Text("No project")
            .font(titleFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 6)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .help("Chats that run in their own folder, not in a project")
    .accessibilityLabel("No project")
  }
}
