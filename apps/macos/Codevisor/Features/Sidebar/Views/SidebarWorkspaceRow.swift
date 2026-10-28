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

  private static let trailingSpacing: CGFloat = 7

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
        ZStack(alignment: .trailing) {
          properties
            .opacity(isHovered ? 0 : 1)
            .allowsHitTesting(!isHovered)
          if isHovered {
            hoverActions.transition(.opacity)
          }
        }
        .frame(minWidth: hoverActionsWidth, alignment: .trailing)
        .animation(.easeOut(duration: 0.12), value: isHovered)
      }
      .padding(.horizontal, 10)
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
        .shortcut(.archiveWorkspace)
      case let .archived(onRestore):
        Button(action: onRestore) {
          Label("Restore", systemImage: "arrow.uturn.backward")
            .labelStyle(.titleAndIcon)
        }
      }
    }
  }

  private var hoverActionsWidth: CGFloat {
    let slots: CGFloat = isArchived ? 1 : 2
    return slots * SidebarRowIcon.trailingSlot + (slots - 1) * Self.trailingSpacing
  }

  private var properties: some View {
    HStack(spacing: Self.trailingSpacing) {
      if let pullRequest {
        PullRequestBadge(
          pullRequest: pullRequest, size: SidebarRowIcon.trailingSize, slot: SidebarRowIcon.trailingSlot)
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
    }
  }

  private var hoverActions: some View {
    HStack(spacing: Self.trailingSpacing) {
      switch lifecycle {
      case let .active(isPinned, onTogglePin, _, _, onArchive):
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
      SidebarWorkspaceLeadingIcon(icon: icon, store: store)
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

enum SidebarRowIcon {
  static let size: CGFloat = 13
  static let trailingSize: CGFloat = 12
  static let trailingSlot: CGFloat = 16
  static let weight: Font.Weight = .regular
}
