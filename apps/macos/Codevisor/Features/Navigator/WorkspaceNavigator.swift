import CodevisorCore
import CodevisorUI
import SwiftUI

/// One of the navigator's views, chosen from the tab bar at its top.
enum NavigatorTab: String, CaseIterable, Codable, Identifiable {
  case files
  case sourceControl

  var id: String { rawValue }

  var title: String {
    switch self {
    case .files: "Files"
    case .sourceControl: "Source Control"
    }
  }

  var systemImage: String {
    switch self {
    case .files: "folder"
    case .sourceControl: "arrow.trianglehead.branch"
    }
  }
}

/// How a workspace's navigator looks on this device: whether it is open and
/// which tab it shows. Each workspace remembers its own.
struct WorkspaceNavigatorState: Codable, Equatable {
  var isPresented = false
  var tab = NavigatorTab.files

  private static func key(_ workspaceId: UUID) -> String { "workspaceNavigator.\(workspaceId.uuidString)" }

  /// Preferences are observable, so a view reading this follows changes.
  static func binding(for workspaceId: UUID) -> Binding<WorkspaceNavigatorState> {
    Binding(
      get: { ClientPreferences.shared.value(forKey: key(workspaceId), default: WorkspaceNavigatorState()) },
      set: { ClientPreferences.shared.set($0, forKey: key(workspaceId)) }
    )
  }
}

/// The workspace's trailing sidebar: Xcode-style navigator tabs over the
/// selected tab's content.
struct WorkspaceNavigator: View {
  @Binding var tab: NavigatorTab
  let fileTree: FileTreeModel
  let sourceControl: SourceControlModel
  /// Whether the workspace's machine serves source control.
  let supportsSourceControl: Bool
  /// The pane facing the user, so each list can highlight its row.
  let activePane: PaneDescriptorState?
  /// A file to show: `preview` puts it in the preview tab.
  let onOpenFile: (String, _ preview: Bool) -> Void
  let onOpenDiff: (SourceControlChange, _ preview: Bool) -> Void
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    VStack(spacing: 0) {
      NavigatorTabBar(selection: $tab, badges: [.sourceControl: sourceControl.count])
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
      switch tab {
      case .files:
        FileTreeView(
          model: fileTree, activePath: activeDocumentPath,
          onPreview: { onOpenFile($0, true) }, onOpen: { onOpenFile($0, false) })
      case .sourceControl:
        SourceControlView(
          model: sourceControl, isSupported: supportsSourceControl, activeChangeId: activeChangeId,
          onOpenDiff: onOpenDiff, onOpenFile: onOpenFile)
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    // The badge stays current from any tab; the list itself, more often.
    .task(id: [tab == .sourceControl, scenePhase == .active, supportsSourceControl]) {
      guard supportsSourceControl else { return }
      await sourceControl.refresh()
      let interval: Duration = tab == .sourceControl ? .seconds(3) : .seconds(15)
      while !Task.isCancelled {
        do { try await Task.sleep(for: interval) } catch { break }
        if scenePhase == .active { await sourceControl.refresh() }
      }
    }
  }

  private var activeDocumentPath: String? {
    activePane?.kind == .document ? activePane?.documentPath : nil
  }

  private var activeChangeId: String? {
    guard let review = activePane?.review, let file = review.file else { return nil }
    return "\(review.mode == .staged ? "staged" : "changes"):\(file)"
  }
}
