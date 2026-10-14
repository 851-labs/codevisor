import SwiftUI

/// A project or machine that groups workspace rows: a disclosure row whose
/// icon becomes a chevron on hover, with a hover new-chat button.
struct SidebarGroupRow: View {
  let title: String
  let systemImage: String
  let isExpanded: Bool
  let isReordering: Bool
  let onToggle: () -> Void
  /// Nil for groups a chat can't start in (an unknown machine).
  let onNewChat: (() -> Void)?

  var body: some View {
    HoverableRow(isHoverEnabled: !isReordering) { isHovered in
      HStack(spacing: 6) {
        // A real Button resolves its hit target at mouse-down, so a click
        // on the hover new-chat button can never also flip the disclosure.
        Button(action: onToggle) {
          HStack(spacing: 7) {
            ZStack {
              Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .opacity(isHovered ? 0 : 1)
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(isHovered ? 1 : 0)
            }
            .frame(width: 18)
            Text(title)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer(minLength: 6)
          }
          .padding(.vertical, 5)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

        if isHovered, let onNewChat {
          Button(action: onNewChat) {
            Image(systemName: "square.and.pencil")
              .font(.callout.weight(.semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("New chat in \(title)")
          .accessibilityLabel("New chat in \(title)")
          // Covered by the row's New Chat action, which does not depend on
          // hover.
          .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(.primary)
    }
    .contextMenu {
      Button(action: onToggle) {
        Label(
          isExpanded ? "Collapse" : "Expand",
          systemImage: isExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
        )
        .labelStyle(.titleAndIcon)
      }
      if let onNewChat {
        Divider()
        Button(action: onNewChat) {
          Label("New Chat", systemImage: "square.and.pencil")
            .labelStyle(.titleAndIcon)
        }
      }
    }
    // Hover only tracks in the key window, so the new-chat button is also
    // a named action for assistive tech and background computer use.
    // Plain-title buttons: SwiftUI drops Label-built ones here.
    .accessibilityActions {
      if let onNewChat { Button("New Chat", action: onNewChat) }
    }
  }
}
