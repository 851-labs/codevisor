import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarWorkspaceRowView: View, Equatable {
  @Environment(\.openURL) private var openURL

  let workspace: HomeSidebarWorkspace
  let actions: HomeSidebarActionHandler
  var isSelectionRow = false

  @State private var confirmsRestore = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.workspace == rhs.workspace && lhs.actions === rhs.actions && lhs.isSelectionRow == rhs.isSelectionRow
  }

  private var ref: HomeSidebarWorkspaceRef { workspace.workspace }

  private var row: HomeSidebarRowLabel { HomeSidebarRowLabel(details: workspace.details) }

  private var offersPin: Bool { workspace.canPin && !workspace.isArchived }

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
    Group {
      if isSelectionRow && !workspace.isArchived {
        row
      } else {
        Button(action: onOpen) { row }
          .buttonStyle(.plain)
      }
    }
    .opacity(workspace.isArchived ? 0.6 : 1)
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      if offersPin {
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
    .confirmationDialog(
      "Restore \(workspace.displayName)?", isPresented: $confirmsRestore, titleVisibility: .visible
    ) {
      Button("Restore Workspace", action: onRestore)
    } message: {
      Text("Archived workspaces open again once they are restored.")
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(workspace.details.accessibilityLabel)
    .accessibilityValue(workspace.isArchived ? "Archived" : "")
    .accessibilityActions {
      if workspace.isArchived {
        Button("Restore", action: onRestore)
      } else {
        if workspace.canPin {
          Button(workspace.isPinned ? "Unpin" : "Pin", action: onTogglePin)
        }
        Button("New Tab", action: onNewTab)
        Button("Rename", action: onRename)
        Button("Archive", action: onArchive)
      }
      if let pullRequest = workspace.pullRequest {
        Button("Open Pull Request") { openURL(pullRequest.url) }
      }
    }
  }
}

struct HomeSidebarGroupLabel: View {
  let heading: SidebarWorkspaceGroup.Heading

  var body: some View {
    Label {
      HomeSidebarRowTitle(title: heading.title)
        .lineLimit(1)
    } icon: {
      HomeSidebarSymbol(image: heading.icon.image)
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
