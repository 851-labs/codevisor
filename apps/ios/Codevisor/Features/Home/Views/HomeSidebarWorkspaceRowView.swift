import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarWorkspaceRowView: View, Equatable {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.openURL) private var openURL

  let workspace: HomeSidebarWorkspace
  let actions: HomeSidebarActionHandler
  var isSelectionRow = false
  var sections: [CustomSection] = []

  @State private var confirmsRestore = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.workspace == rhs.workspace && lhs.actions === rhs.actions && lhs.isSelectionRow == rhs.isSelectionRow
      && lhs.sections == rhs.sections
  }

  private var ref: HomeSidebarWorkspaceRef { workspace.workspace }

  private func onOpen() {
    if workspace.isArchived {
      confirmsRestore = true
    } else {
      actions.actions.openWorkspace(workspace)
    }
  }

  private func onTogglePin() { actions.actions.togglePin(ref) }
  private func onNewTab() { actions.actions.newTab(ref) }
  private func onRename() { actions.actions.renameWorkspace(ref) }
  private func onArchive() { actions.actions.archiveWorkspace(ref) }
  private func onRestore() { actions.actions.restoreWorkspace(ref) }

  var body: some View {
    HStack(spacing: 10) {
      if isSelectionRow && !workspace.isArchived {
        label
      } else {
        Button(action: onOpen) { label }
          .buttonStyle(.plain)
      }
      trailingDetails
    }
    .opacity(workspace.isArchived ? 0.6 : 1)
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      if !workspace.isArchived {
        Button(action: onTogglePin) {
          Image(systemName: workspace.isPinned ? "pin.slash" : "pin")
        }
        .tint(.orange)
        .accessibilityLabel(workspace.isPinned ? "Unpin" : "Pin")
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      if workspace.isArchived {
        Button(action: onRestore) {
          Image(systemName: "arrow.uturn.backward")
        }
        .tint(.blue)
        .accessibilityLabel("Restore")
      } else {
        Button(action: onArchive) {
          Image(systemName: "archivebox")
        }
        .tint(.indigo)
        .accessibilityLabel("Archive")
        Button(action: onRename) {
          Image(systemName: "pencil")
        }
        .tint(.gray)
        .accessibilityLabel("Rename")
      }
    }
    .contextMenu { menu }
    .confirmationDialog(
      "Restore \(workspace.displayName)?", isPresented: $confirmsRestore, titleVisibility: .visible
    ) {
      Button("Restore Workspace", action: onRestore)
    } message: {
      Text("Archived workspaces open again once they are restored.")
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(workspace.isArchived ? "Archived" : "")
    .accessibilityActions {
      if workspace.isArchived {
        Button("Restore", action: onRestore)
      } else {
        Button(workspace.isPinned ? "Unpin" : "Pin", action: onTogglePin)
        Button("New Tab", action: onNewTab)
        Button("Rename", action: onRename)
        Button("Archive", action: onArchive)
      }
      if let pullRequest = workspace.pullRequest {
        Button("Open Pull Request") { openURL(pullRequest.url) }
      }
    }
  }

  @ViewBuilder
  private var menu: some View {
    if workspace.isArchived {
      Button(action: onRestore) {
        Label("Restore", systemImage: "arrow.uturn.backward")
      }
    } else {
      if let open = actions.actions.openWorkspaceInNewWindow {
        Button {
          open(workspace)
        } label: {
          Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }
        Divider()
      }
      Button(action: onTogglePin) {
        Label(workspace.isPinned ? "Unpin" : "Pin", systemImage: workspace.isPinned ? "pin.slash" : "pin")
      }
      Button(action: onNewTab) {
        Label("New Tab", systemImage: "plus.square.on.square")
      }
      Button(action: onRename) {
        Label("Rename", systemImage: "pencil")
      }
      if let slot = workspace.sectionSlot {
        Divider()
        MoveToSectionMenu(
          currentSectionID: slot.sectionID, sections: sections,
          move: { actions.actions.moveToSection(ref, $0) }, newSection: { actions.actions.newSection(ref) })
      }
      Divider()
      Button(action: onArchive) {
        Label("Archive", systemImage: "archivebox")
      }
    }
  }

  private var label: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        HomeSidebarRowTitle(title: workspace.displayName)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        if let subtitle = workspace.subtitle {
          HomeSidebarRowSubtitle(text: subtitle)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } icon: {
      leadingIcon
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var leadingIcon: some View {
    if let row = workspace.leadingRow {
      HomeSidebarTabIcon(row: row, serverId: workspace.serverId)
    } else {
      HomeSidebarSymbol(name: EntitySystemSymbol.workspace)
    }
  }

  @ViewBuilder
  private var trailingDetails: some View {
    if let pullRequest = workspace.pullRequest {
      PullRequestBadge(pullRequest: pullRequest, size: 15, slot: 22)
    }
    if let machine = workspace.machine {
      HomeSidebarSymbol(name: machine.systemImage)
        .imageScale(.small)
    }
    if !workspace.hasNestedRows && !workspace.isArchived {
      Image(systemName: "chevron.forward")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
  }

  private var accessibilityLabel: String {
    let status: String? =
      switch workspace.status {
      case .error: "error"
      case .actionRequired: "needs attention"
      case .unread: "unread"
      case .inProgress: "working"
      case .idle: nil
      }
    return [
      workspace.displayName, status, workspace.subtitle,
      workspace.pullRequest.map { "pull request \($0.number)" },
      workspace.machine.map { "on \($0.name)" },
    ].compactMap { $0 }.joined(separator: ", ")
  }
}

struct HomeSidebarGroupLabel: View {
  let heading: SidebarWorkspaceGroup.Heading
  let onNewChat: (() -> Void)?

  var body: some View {
    Label {
      HomeSidebarRowTitle(title: heading.title)
        .lineLimit(1)
    } icon: {
      HomeSidebarSymbol(image: heading.icon.image)
    }
    .contextMenu {
      if let onNewChat {
        Button(action: onNewChat) {
          Label("New Chat", systemImage: "square.and.pencil")
        }
      }
    }
  }
}

struct HomeSidebarRowTitle: View {
  let title: String
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    Text(title)
      .font(.body)
      .foregroundStyle(backgroundProminence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
  }
}

private struct HomeSidebarRowSubtitle: View {
  let text: String
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    Text(text)
      .font(.caption)
      .lineLimit(1)
      .foregroundStyle(
        backgroundProminence == .increased ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
  }
}

struct HomeSidebarSymbol: View {
  let image: Image
  @Environment(\.backgroundProminence) private var backgroundProminence

  init(name: String) {
    image = Image(systemName: name)
  }

  init(image: Image) {
    self.image = image
  }

  var body: some View {
    image
      .symbolRenderingMode(.monochrome)
      .foregroundStyle(backgroundProminence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      .accessibilityHidden(true)
  }
}
