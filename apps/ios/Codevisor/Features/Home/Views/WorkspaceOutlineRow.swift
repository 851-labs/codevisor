import CodevisorClient
import CodevisorCore
import SwiftUI

/// A workspace in an outline, as Notes lists a folder: its state, its name
/// and how many workspaces are nested right under it. A workspace with workspaces nested under it has
/// a chevron that discloses them inline, one level per tap; tapping the row
/// itself opens the workspace's page.
struct WorkspaceOutlineRow: View {
  @Environment(\.workspaceRowActions) private var actions
  @Environment(\.homeLayoutMode) private var layoutMode

  let row: AgentSidebarRow
  /// The workspace it is nested under, if any.
  let owner: AgentSidebarRow?
  /// Rows disclosed on this device. Disclosure isn't synced, as in Notes.
  @Binding var expanded: Set<UUID>
  /// Beside a sidebar the row is a selection tag; on a phone, a link.
  /// On a page beside a sidebar it selects its workspace there, as Notes
  /// does a subfolder.
  var isSelectable = false
  /// How many workspaces it is nested under in this outline.
  var depth = 0

  private static let indent: CGFloat = 20

  private var isExpanded: Bool { expanded.contains(row.id) }

  /// The outline is drawn by `WorkspaceOutline` rather than
  /// `DisclosureGroup`, whose chevron can't be restyled: a softer chevron
  /// than the label's, still stronger than a link's, so it reads as
  /// something to tap.
  var body: some View {
    label
  }

  @ViewBuilder
  private var label: some View {
    let hasChildren = !row.children.isEmpty
    let content = HStack(spacing: 10) {
      HomeAgentMark(status: row.status, harnessId: row.harnessId)
      Text(row.title).lineLimit(1)
      Spacer(minLength: 0)
      HStack(spacing: 0) {
        // As Notes counts a folder's subfolders: the workspaces nested
        // right under this one, when it has any.
        if !row.children.isEmpty {
          Text("\(row.children.count)").foregroundStyle(.secondary).monospacedDigit()
        }
        if hasChildren { disclosure }
      }
    }
    .padding(.leading, CGFloat(depth) * Self.indent)
    Group {
      if isSelectable {
        content.tag(row.id)
      } else if hasChildren || layoutMode == .split {
        // A link would add its own chevron beside the disclosure one.
        Button {
          actions.openPage(row.serverId, row.id)
        } label: {
          content
        }
        .foregroundStyle(.primary)
      } else {
        NavigationLink(value: HomeRoute.agent(serverId: row.serverId, workspaceId: row.id)) { content }
      }
    }
    .accessibilityActions {
      if hasChildren {
        Button(isExpanded ? "Collapse" : "Expand", action: toggle)
      }
    }
    .swipeActions(edge: .trailing) {
      Button("Archive", systemImage: "archivebox", role: .destructive) { actions.archive(row.id) }
    }
    .contextMenu { WorkspaceRowMenu(row: row, owner: owner) }
  }

  private var disclosure: some View {
    Button(action: toggle) {
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        // Where a link's chevron sits, as far from the count.
        .padding(.trailing, 2)
        .frame(width: 23, height: 24, alignment: .trailing)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
  }

  private func toggle() {
    withAnimation {
      if isExpanded { expanded.remove(row.id) } else { expanded.insert(row.id) }
    }
  }
}

/// A workspace row's menu: rename, re-file, un-nest, archive.
struct WorkspaceRowMenu: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.workspaceRowActions) private var actions
  let row: AgentSidebarRow
  let owner: AgentSidebarRow?

  private var navigation: NavigationStore { environment.navigationStore }

  var body: some View {
    Button("Rename", systemImage: "pencil") { actions.rename(row.id) }
    if let owner {
      Button("Move Out of “\(owner.title)”", systemImage: "arrow.up.left") { change(.owner(nil)) }
    } else if navigation.sidebarGrouping == .none, !navigation.folders.isEmpty {
      Menu("Move to Folder", systemImage: "folder") {
        ForEach(navigation.folders, id: \.id) { folder in
          Button(folder.name) { change(.folder(UUID(uuidString: folder.id))) }
        }
        if environment.workspaces.workspace(id: row.id)?.folderId != nil {
          Divider()
          Button("Remove from Folder") { change(.folder(nil)) }
        }
      }
    }
    let owned = row.children.count
    Button(
      owned == 0 ? "Archive" : "Archive with \(owned) Workspace\(owned == 1 ? "" : "s")",
      systemImage: "archivebox", role: .destructive
    ) {
      actions.archive(row.id)
    }
  }

  private func change(_ change: WorkspaceHierarchyChange) {
    guard let workspace = environment.workspaces.workspace(id: row.id) else { return }
    navigation.enqueue(
      .updateWorkspaceHierarchy(workspaceId: row.id, change: change), machineId: workspace.serverId)
  }
}
