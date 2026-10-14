import CodevisorCore
import CodevisorUI
import SwiftUI

extension SessionContainerView {
  /// This workspace's navigator state on this device.
  var navigatorState: Binding<WorkspaceNavigatorState> {
    WorkspaceNavigatorState.binding(for: mountedWorkspace.id)
  }

  /// Whether the trailing navigator column shows; never without its flag.
  var showsNavigator: Binding<Bool> {
    let state = navigatorState
    return Binding(
      get: { FeatureFlag.sidebarRefresh.isEnabled && state.wrappedValue.isPresented },
      set: { state.wrappedValue.isPresented = $0 }
    )
  }

  func toggleNavigator() {
    guard FeatureFlag.sidebarRefresh.isEnabled else { return }
    navigatorState.wrappedValue.isPresented.toggle()
  }

  @ToolbarContentBuilder
  var navigatorToolbarItem: some ToolbarContent {
    if FeatureFlag.sidebarRefresh.isEnabled {
      ToolbarItem(placement: .primaryAction) {
        // A toolbar Toggle draws its own on-state; the tooltip names the action.
        Toggle(isOn: showsNavigator) {
          Label("Navigator", systemImage: "sidebar.trailing")
        }
        .help(
          "\(showsNavigator.wrappedValue ? "Hide" : "Show") Navigator (\(ShortcutCatalog.display(for: .toggleNavigator)))"
        )
      }
    }
  }

  func workspaceNavigator(in workspace: Workspace) -> some View {
    let root = workspace.rootDirectory ?? session?.cwd ?? project.folderURL.path
    let client = environment.machines.client(for: workspace.serverId)
    return WorkspaceNavigator(
      tab: navigatorState.tab,
      fileTree: store.fileTree(workspaceId: workspace.id, root: root, client: client),
      sourceControl: store.sourceControl(workspaceId: workspace.id, root: root, client: client),
      supportsSourceControl: environment.machines.statusByMachineId[workspace.serverId]?.supportsGitChanges == true,
      activePane: activePaneDescriptor,
      onOpenFile: { openFileDocument($0, preview: $1) },
      onOpenDiff: { openFileDiff($0.path, staged: $0.isStaged, preview: $1) }
    )
    .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
  }
}
