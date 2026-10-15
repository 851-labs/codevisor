import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarWorkspaceRow: View {
  enum Lifecycle {
    case active(
      isPinned: Bool, onTogglePin: () -> Void, onNewTab: () -> Void, onRename: () -> Void, onArchive: () -> Void
    )
    case archived(onRestore: () -> Void)
  }

  let name: String
  var subtitle: String? = nil
  let icon: SidebarWorkspaceIcon
  let store: SessionStore?
  var pullRequest: ServerGitPullRequest? = nil
  var machine: SidebarRowMachine? = nil
  let isSelected: Bool
  let isReordering: Bool
  let onActivate: () -> Void
  let lifecycle: Lifecycle
  @GestureState private var isPressed = false

  private var isArchived: Bool {
    if case .archived = lifecycle { return true }
    return false
  }

  var body: some View {
    HoverableRow(
      isSelected: isSelected,
      isHoverEnabled: !isReordering,
      isHoverForced: false
    ) { isHovered in
      HStack(spacing: 7) {
        SidebarWorkspaceRowLabel(name: name, subtitle: subtitle, icon: icon, store: store)
          .opacity(isArchived ? 0.8 : 1)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0)
              .updating($isPressed) { _, isPressed, _ in
                guard !isPressed else { return }
                isPressed = true
                onActivate()
              }
          )
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
          .accessibilityValue("Archived", isEnabled: isArchived)
          .accessibilityAction(.default, onActivate)
          .accessibilityActions {
            switch lifecycle {
            case let .active(isPinned, onTogglePin, onNewTab, onRename, onArchive):
              Button(isPinned ? "Unpin" : "Pin", action: onTogglePin)
              Button("New Tab", action: onNewTab)
              Button("Rename", action: onRename)
              Button("Archive", action: onArchive)
            case let .archived(onRestore):
              Button("Restore", action: onRestore)
            }
          }
        if let pullRequest {
          SidebarPullRequestBadge(pullRequest: pullRequest)
        }
        if let machine {
          Image(systemName: machine.systemImage)
            .font(.system(size: SidebarRowIcon.trailingSize, weight: SidebarRowIcon.weight))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.secondary)
            .frame(width: SidebarRowIcon.trailingSlot, height: SidebarRowIcon.trailingSlot)
            .help(machine.name)
            .accessibilityLabel("On \(machine.name)")
        }
        if isHovered {
          hoverAction
        }
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .contextMenu {
      switch lifecycle {
      case let .active(isPinned, onTogglePin, _, onRename, onArchive):
        Button(action: onTogglePin) {
          Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
            .labelStyle(.titleAndIcon)
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
      case let .archived(onRestore):
        Button(action: onRestore) {
          Label("Restore", systemImage: "arrow.uturn.backward")
            .labelStyle(.titleAndIcon)
        }
      }
    }
  }

  @ViewBuilder
  private var hoverAction: some View {
    switch lifecycle {
    case let .active(_, _, _, _, onArchive):
      hoverButton(systemImage: "archivebox", help: "Archive workspace", label: "Archive", action: onArchive)
    case let .archived(onRestore):
      hoverButton(
        systemImage: "arrow.uturn.backward", help: "Restore workspace", label: "Restore", action: onRestore
      )
    }
  }

  private func hoverButton(
    systemImage: String, help: String, label: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: SidebarRowIcon.trailingSize, weight: SidebarRowIcon.weight))
        .frame(width: SidebarRowIcon.trailingSlot, height: SidebarRowIcon.trailingSlot)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
    .accessibilityLabel("\(label) \(SidebarWorkspaceRowLabel.title(for: name))")
    .accessibilityHidden(true)
  }
}

struct SidebarWorkspaceRowLabel: View {
  let name: String
  var subtitle: String? = nil
  let icon: SidebarWorkspaceIcon
  let store: SessionStore?

  static func title(for name: String) -> String {
    name.isEmpty ? "Workspace" : name
  }

  var body: some View {
    HStack(spacing: 7) {
      leadingIcon
      VStack(alignment: .leading, spacing: 2) {
        Text(Self.title(for: name))
          .lineLimit(1)
          .truncationMode(.middle)
        if let subtitle {
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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

struct SidebarRowMachine: Equatable {
  let name: String
  let systemImage: String
}

enum SidebarWorkspaceIcon: Equatable {
  case chat(ChatSession)
  case workingTerminal
  case workspace
}

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

enum SidebarRowIcon {
  static let size: CGFloat = 13
  static let trailingSize: CGFloat = 12
  static let trailingSlot: CGFloat = 16
  static let weight: Font.Weight = .regular
}
