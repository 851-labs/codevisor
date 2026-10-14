import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

/// One workspace in the sidebar: its chat's icon and name, then the
/// properties the Properties menu turns on (its pull request, its machine,
/// when it last changed). Its tabs live in the strip above the workspace's
/// content.
struct SidebarWorkspaceRow: View {
  let name: String
  let icon: SidebarWorkspaceIcon
  let store: SessionStore?
  /// When the workspace last changed, shown as an elapsed time. Nil hides
  /// it (the Properties menu's Updated option is off).
  var updatedAt: Date? = nil
  /// The workspace branch's pull request, shown as a badge that opens it.
  /// Nil hides it.
  var pullRequest: ServerGitPullRequest? = nil
  /// The machine the workspace runs on, shown as its glyph. Nil hides it.
  var machine: SidebarRowMachine? = nil
  let isSelected: Bool
  let isReordering: Bool
  let onActivate: () -> Void
  let onNewTab: () -> Void
  let onRename: () -> Void
  let onArchive: () -> Void
  var isPinned = false
  /// Nil hides Pin/Unpin (previews).
  var onTogglePin: (() -> Void)? = nil
  /// Latches one activation per press; resets when the gesture ends or is
  /// cancelled.
  @GestureState private var isPressed = false

  var body: some View {
    HoverableRow(
      isSelected: isSelected,
      isHoverEnabled: !isReordering,
      isHoverForced: false
    ) { isHovered in
      HStack(spacing: 7) {
        SidebarWorkspaceRowLabel(name: name, icon: icon, store: store)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
          // Only the label activates on pointer-down. The archive button is
          // a sibling, so pressing it cannot select the row first.
          .gesture(
            DragGesture(minimumDistance: 0)
              .updating($isPressed) { _, isPressed, _ in
                guard !isPressed else { return }
                isPressed = true
                onActivate()
              }
          )
          // Pointer-down selection and the hover-only archive button are
          // invisible to accessibility. Expose them as actions so assistive
          // tech and background computer use can select and manage the
          // workspace without hovering or focusing the window.
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
          .accessibilityAction(.default, onActivate)
          // Plain-title buttons: SwiftUI drops Label-built ones here.
          .accessibilityActions {
            if let onTogglePin { Button(isPinned ? "Unpin" : "Pin", action: onTogglePin) }
            Button("New Tab", action: onNewTab)
            Button("Rename", action: onRename)
            Button("Archive", action: onArchive)
          }
        if let pullRequest {
          SidebarPullRequestBadge(pullRequest: pullRequest)
        }
        if let machine {
          Image(systemName: machine.systemImage)
            .font(.system(size: SidebarRowIcon.trailingSize, weight: SidebarRowIcon.weight))
            // The display's screen is a second, translucent layer even in
            // monochrome; clearing it leaves the outline the row's other
            // glyphs use.
            .symbolRenderingMode(.palette)
            .foregroundStyle(.secondary, .clear)
            .frame(width: SidebarRowIcon.trailingSlot, height: SidebarRowIcon.trailingSlot)
            .help(machine.name)
            .accessibilityLabel("On \(machine.name)")
        }
        // One trailing slot: the archive button on hover, flush right with
        // the glyphs' spacing, else the elapsed time.
        if isHovered {
          Button(action: onArchive) {
            Image(systemName: "archivebox")
              .font(.system(size: SidebarRowIcon.trailingSize, weight: SidebarRowIcon.weight))
              // The same slot as the PR and machine glyphs, so the three sit
              // evenly spaced.
              .frame(width: SidebarRowIcon.trailingSlot, height: SidebarRowIcon.trailingSlot)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Archive workspace")
          .accessibilityLabel("Archive \(SidebarWorkspaceRowLabel.title(for: name))")
          // Covered by the row's Archive action, which does not depend on
          // hover.
          .accessibilityHidden(true)
        } else if let updatedAt {
          // Re-reads the clock each minute so the time keeps counting.
          TimelineView(.everyMinute) { context in
            Text(RelativeTime.short(from: updatedAt, now: context.date))
              .font(.caption2)
              .monospacedDigit()
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .fixedSize()
          }
          .frame(minWidth: 24, minHeight: 14, alignment: .trailing)
          .help(updatedAt.formatted(date: .abbreviated, time: .shortened))
        }
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .contextMenu {
      if let onTogglePin {
        Button(action: onTogglePin) {
          Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
            .labelStyle(.titleAndIcon)
        }
      }
      Button(action: onRename) {
        Label("Rename", systemImage: "pencil")
          .labelStyle(.titleAndIcon)
      }
      Divider()
      Button(action: onArchive) {
        Label("Archive", systemImage: "archivebox")
          .labelStyle(.titleAndIcon)
      }
    }
  }
}

/// The row's icon and name, shared with the reorder ghost so the lifted row
/// and its stand-in never drift apart in style.
struct SidebarWorkspaceRowLabel: View {
  let name: String
  let icon: SidebarWorkspaceIcon
  let store: SessionStore?

  static func title(for name: String) -> String {
    name.isEmpty ? "Workspace" : name
  }

  var body: some View {
    HStack(spacing: 7) {
      leadingIcon
      Text(Self.title(for: name))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    // Native sidebar rows keep the label color whether or not they are
    // selected; only the glyph reads as secondary.
    .foregroundStyle(.primary)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var leadingIcon: some View {
    switch icon {
    case let .chat(session):
      ChatSessionLeadingIcon(
        session: session, store: store, activityColor: .secondary, iconSize: SidebarRowIcon.size
      )
      .foregroundStyle(.secondary)
    case .workingTerminal:
      AgentStatusIndicator(status: .working)
        .frame(width: 18)
    case .workspace:
      Image(systemName: EntitySystemSymbol.workspace)
        .frame(width: 18)
        .foregroundStyle(.secondary)
    }
  }
}

/// A workspace's machine as its row shows it: the machine's glyph, named
/// in the tooltip.
struct SidebarRowMachine: Equatable {
  let name: String
  let systemImage: String

  /// A machine's outline glyph in the sidebar, matching the rows' line
  /// icons: a display for this Mac, a cloud for any other machine.
  static func systemImage(isLocal: Bool) -> String {
    isLocal ? "display" : "cloud"
  }
}

/// What a workspace row's icon shows: one of its chats (the chat's status,
/// else its model), an agent terminal that is working, or, for a workspace
/// with neither, the workspace glyph.
enum SidebarWorkspaceIcon: Equatable {
  case chat(ChatSession)
  case workingTerminal
  case workspace
}

/// GitHub's own pull request icon for the state (Primer Octicons, bundled as
/// template images), colored GitHub's way with an open pull request's color
/// following its checks; clicking opens it in the browser.
struct SidebarPullRequestBadge: View {
  let pullRequest: ServerGitPullRequest

  var body: some View {
    Button {
      NSWorkspace.shared.open(pullRequest.url)
    } label: {
      Image(iconName)
        .resizable()
        .scaledToFit()
        .frame(width: SidebarRowIcon.trailingSize, height: SidebarRowIcon.trailingSize)
        .foregroundStyle(color)
        .frame(width: SidebarRowIcon.trailingSlot, height: SidebarRowIcon.trailingSlot)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("#\(pullRequest.number) · \(pullRequest.title) (\(summary))")
    .accessibilityLabel("Pull request \(pullRequest.number), \(summary)")
  }

  private var iconName: String {
    switch pullRequest.state {
    case .open: pullRequest.isDraft ? "octicon-git-pull-request-draft" : "octicon-git-pull-request"
    case .merged: "octicon-git-merge"
    case .closed: "octicon-git-pull-request-closed"
    }
  }

  private var summary: String {
    guard let checksTitle else { return stateTitle }
    return "\(stateTitle), \(checksTitle)"
  }

  private var checksTitle: String? {
    switch pullRequest.checks {
    case .passing: "checks passing"
    case .failing: "checks failing"
    case .pending: "checks running"
    case .none: nil
    }
  }

  private var stateTitle: String {
    switch pullRequest.state {
    case .open: pullRequest.isDraft ? "Draft" : "Open"
    case .merged: "Merged"
    case .closed: "Closed"
    }
  }

  private var color: Color {
    switch pullRequest.state {
    case .open where pullRequest.isDraft: .secondary
    case .open:
      switch pullRequest.checks {
      case .failing: .red
      case .pending: .orange
      case .passing, .none: .green
      }
    case .merged: .purple
    case .closed: .red
    }
  }
}

/// Glyph sizes and stroke weight for sidebar rows. Leading icons (the model
/// logo, a group's project or machine) draw at 14pt; the trailing glyphs (PR
/// badge, machine, archive) sit 2pt smaller, each in its own slot. SF Symbols
/// at regular weight and GitHub's 24px Octicons draw matching strokes at the
/// same size (the 16px Octicons would be heavier, like SF's
/// medium-to-semibold).
enum SidebarRowIcon {
  static let size: CGFloat = 14
  static let trailingSize: CGFloat = 12
  /// A trailing glyph's slot: the glyph plus 2pt either side.
  static let trailingSlot: CGFloat = 16
  static let weight: Font.Weight = .regular
}
