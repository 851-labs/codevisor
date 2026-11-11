import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarWorkspaceRow: View {
  enum Lifecycle {
    case active(
      isPinned: Bool, onTogglePin: () -> Void, onRename: () -> Void, onArchive: () -> Void
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
  var sectionMenu: MoveToSectionMenu? = nil

  static let trailingSpacing: CGFloat = 7

  private var isArchived: Bool {
    if case .archived = lifecycle { return true }
    return false
  }

  private var archivedOpacity: Double { isArchived ? 0.6 : 1 }

  private var unreadChat: ChatSession? {
    guard case let .chat(session, isQuiet: false) = icon else { return nil }
    return session
  }

  var body: some View {
    HoverableRow(
      isSelected: isSelected,
      isHoverEnabled: !isReordering,
      isHoverForced: false
    ) { isHovered in
      HStack(spacing: 7) {
        SidebarWorkspaceRowLabel(name: name, subtitle: subtitle, icon: icon, store: store)
          .opacity(archivedOpacity)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
          .onSidebarRowPress(perform: onActivate)
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
          .accessibilityValue(isArchived ? "Archived" : "")
          .accessibilityAction(.default, onActivate)
          .accessibilityActions {
            switch lifecycle {
            case let .active(isPinned, onTogglePin, onRename, onArchive):
              Button(isPinned ? "Unpin" : "Pin", action: onTogglePin)
              Button("Rename", action: onRename)
              Button("Archive", action: onArchive)
            case let .archived(onRestore):
              Button("Restore", action: onRestore)
            }
          }
        if isHovered {
          hoverActions
        } else {
          SidebarWorkspaceRowProperties(pullRequest: pullRequest, machine: machine)
            .opacity(archivedOpacity)
        }
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .contextMenu {
      switch lifecycle {
      case let .active(isPinned, onTogglePin, onRename, onArchive):
        if let unreadChat {
          ChatSessionUnreadMenuItem(session: unreadChat)
          Divider()
        }
        Button(action: onTogglePin) {
          Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
            .labelStyle(.titleAndIcon)
        }
        Button(action: onRename) {
          Label("Rename", systemImage: "pencil")
            .labelStyle(.titleAndIcon)
        }
        if let sectionMenu {
          Divider()
          sectionMenu
        }
        Divider()
        Button(action: onArchive) {
          Label("Archive", systemImage: "archivebox")
            .labelStyle(.titleAndIcon)
        }
        .shortcut(.archiveWorkspace)
      case let .archived(onRestore):
        Button(action: onRestore) {
          Label("Restore", systemImage: "arrow.uturn.backward")
            .labelStyle(.titleAndIcon)
        }
      }
    }
  }

  private var hoverActions: some View {
    HStack(spacing: Self.trailingSpacing) {
      switch lifecycle {
      case let .active(isPinned, onTogglePin, _, onArchive):
        hoverButton(
          systemImage: isPinned ? "pin.slash" : "pin",
          help: isPinned ? "Unpin workspace" : "Pin workspace",
          label: isPinned ? "Unpin" : "Pin",
          action: onTogglePin
        )
        hoverButton(systemImage: "archivebox", help: "Archive workspace", label: "Archive", action: onArchive)
      case let .archived(onRestore):
        hoverButton(
          systemImage: "arrow.uturn.backward", help: "Restore workspace", label: "Restore", action: onRestore
        )
      }
    }
  }

  private func hoverButton(
    systemImage: String, help: String, label: String, action: @escaping () -> Void
  ) -> some View {
    SidebarRowHoverButton(
      systemImage: systemImage, help: help,
      accessibilityLabel: "\(label) \(SidebarWorkspaceRowLabel.title(for: name))", action: action)
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
      SidebarWorkspaceLeadingIcon(icon: icon, store: store)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(Self.title(for: name))
          .lineLimit(1)
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
}

struct SidebarRowMachine: Equatable {
  let name: String
  let systemImage: String
}

enum SidebarWorkspaceIcon: Equatable {
  case chat(ChatSession, isQuiet: Bool = false)
  case workingTerminal
  case workspace
}

enum SidebarRowIcon {
  static let size: CGFloat = 13
  static let trailingSize: CGFloat = 12
  static let trailingSlot: CGFloat = 16
  static let weight: Font.Weight = .regular
}
