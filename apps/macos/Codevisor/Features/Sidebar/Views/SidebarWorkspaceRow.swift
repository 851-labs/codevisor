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
  var isExpanded: Bool? = nil
  var onToggleChildren: () -> Void = {}
  let onActivate: () -> Void
  let lifecycle: Lifecycle
  var sectionMenu: MoveToSectionMenu? = nil
  @GestureState private var isPressed = false

  static let trailingSpacing: CGFloat = 7

  private var isArchived: Bool {
    if case .archived = lifecycle { return true }
    return false
  }

  private var archivedOpacity: Double { isArchived ? 0.6 : 1 }

  var body: some View {
    HoverableRow(
      isSelected: isSelected,
      isHoverEnabled: !isReordering,
      isHoverForced: false
    ) { isHovered in
      HStack(spacing: 7) {
        SidebarWorkspaceRowLabel(
          name: name, subtitle: subtitle, icon: icon, store: store, isExpanded: isExpanded,
          showsChevron: isExpanded != nil && isHovered && !isReordering, onToggle: onToggleChildren
        )
        .opacity(archivedOpacity)
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
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(.default, onActivate)
        .accessibilityActions {
          if let isExpanded {
            Button(isExpanded ? "Collapse" : "Expand", action: onToggleChildren)
          }
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
      case let .active(isPinned, onTogglePin, _, onRename, onArchive):
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

  private var accessibilityValue: String {
    if isArchived { return "Archived" }
    return isExpanded.map { $0 ? "Expanded" : "Collapsed" } ?? ""
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
  var isExpanded: Bool? = nil
  var showsChevron = false
  var onToggle: () -> Void = {}

  static func title(for name: String) -> String {
    name.isEmpty ? "Workspace" : name
  }

  var body: some View {
    HStack(spacing: 7) {
      SidebarWorkspaceLeadingIcon(icon: icon, store: store)
        .opacity(showsChevron ? 0 : 1)
        .frame(width: 18)
        .overlay {
          if let isExpanded {
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
              .frame(width: 18, height: 18)
              .contentShape(Rectangle())
              .highPriorityGesture(TapGesture().onEnded(onToggle))
              .opacity(showsChevron ? 1 : 0)
              .allowsHitTesting(showsChevron)
              .help(isExpanded ? "Collapse \(Self.title(for: name))" : "Expand \(Self.title(for: name))")
              .accessibilityHidden(true)
          }
        }
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
