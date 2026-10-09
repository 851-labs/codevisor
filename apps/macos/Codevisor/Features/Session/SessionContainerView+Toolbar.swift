import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import ComposableArchitecture
import SimulatorPane
import SwiftUI

extension SessionContainerView {
  /// The window title (Mission Control, the Window menu) names the active
  /// pane; the toolbar row shows the tabs instead of it.
  @ViewBuilder
  var titledContentColumn: some View {
    if let model = activeFileModel {
      paneColumn.navigationTitle(model.title)
    } else {
      paneColumn.navigationTitle(activePaneTitle)
    }
  }

  /// The pane under its own controls, when it has any: a slim second row
  /// below the tab bar, so the tab bar stays the toolbar's only content and
  /// a chat (which has no controls) looks exactly like it did without tabs.
  private var paneColumn: some View {
    contentColumn.safeAreaInset(edge: .top, spacing: 0) {
      if let browser = activeBrowserModel {
        // The browser's controls carry their own glass at full size.
        VStack(spacing: 0) {
          ChromiumBrowserPaneControls(model: browser)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
          Divider()
        }
      } else if hasPaneControls {
        VStack(spacing: 0) {
          paneControls
            .controlSize(.small)
            .buttonStyle(.accessoryBar)
            .padding(.horizontal, 10)
            .frame(height: 36)
          Divider()
        }
      }
    }
  }

  private var hasPaneControls: Bool {
    activeBrowserModel != nil || activeScreenSharingPane != nil || activeFileModel != nil
      || activeReviewModel != nil || activeSimulatorModel?.device != nil
  }

  @ViewBuilder
  private var paneControls: some View {
    if let pane = activeScreenSharingPane, let store = pane.store {
      ScreenSharingControls(
        store: store, settings: { pane.machineSettings() }, applySettings: { pane.applyMachineSettings($0) })
    } else if let model = activeFileModel {
      FilePaneControls(model: model, onNewTab: addCenterTab)
    } else if let model = activeReviewModel {
      ReviewPaneControls(model: model, title: activePaneTitle.wrappedValue)
    } else if let model = activeSimulatorModel {
      SimulatorPaneControls(model: model)
    }
  }

  /// Resolve within the selected tab, even during the frame between a tab
  /// change and its focus callback. A stale split must never own pane controls.
  private var activeToolbarGroup: PaneGroupModel? {
    let workspace = selectedWorkspace
    guard let leafId = workspace.selectedCenterTab?.resolvedActiveLeafId(preferred: activeLeafId) else { return nil }
    return configuredCenterModel(leafId: leafId)
  }

  var activePaneDescriptor: PaneDescriptorState? {
    guard let leafId = activeLeafId else { return nil }
    return selectedWorkspace.selectedPane(inLeaf: leafId)
  }

  var activeBrowserModel: ChromiumBrowserModel? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .browser else { return nil }
    return (group.selectedPane as? BrowserPane)?.model
  }

  var activeFileModel: FilePaneModel? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .document else { return nil }
    return (group.selectedPane as? FilePane)?.model
  }

  var activeReviewModel: ReviewPaneModel? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .review else { return nil }
    return (group.selectedPane as? ReviewPane)?.model
  }

  var activeSimulatorModel: SimulatorPaneModel? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .simulator else { return nil }
    return (group.selectedPane as? AppleSimulatorPane)?.model
  }

  var activeScreenSharingPane: ScreenSharingPane? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .screenSharing,
      let pane = group.selectedPane as? ScreenSharingPane, pane.store != nil
    else { return nil }
    return pane
  }

  /// Chats retain the editable title and context previously used in Nous.
  /// Connected screen sharing names the remote Mac; browser and file controls replace the title.
  var activePaneTitle: Binding<String> {
    Binding(
      get: {
        if let pane = activeScreenSharingPane { return pane.connectionName }
        if let device = activeSimulatorModel?.device { return device.name }
        guard let descriptor = activePaneDescriptor else { return "New Tab" }
        if descriptor.kind == .browser { return "" }
        let workspace = selectedWorkspace
        if descriptor.kind == .chat { return paneTitle(descriptor) }
        return workspace.selectedCenterTab?.customTitle ?? paneTitle(descriptor)
      },
      set: { title in
        guard activePaneDescriptor?.kind != .browser, activeReviewModel == nil,
          activeScreenSharingPane == nil, activeFileModel == nil, activeSimulatorModel?.device == nil
        else { return }
        let workspace = selectedWorkspace
        renameCenterTab(workspace.selectedCenterTabId, to: title)
      }
    )
  }

  var activePaneSubtitle: String {
    if let store = activeScreenSharingPane?.store {
      guard let display = store.displays.first(where: { $0.id == store.selectedDisplayId }), display.width > 0 else {
        return ""
      }
      return "\(display.width) × \(display.height)"
    }
    if activeSimulatorModel?.device != nil { return "" }
    guard activePaneDescriptor?.kind == .chat else { return "" }
    let workspace = selectedWorkspace
    let candidates: [String?] = [
      workspace.name,
      project.name,
      workspace.worktreeName,
      environment.machines.fleetMachineName(for: workspace.serverId),
    ]
    var parts: [String] = []
    for candidate in candidates {
      guard let candidate, !candidate.isEmpty, !parts.contains(candidate) else { continue }
      parts.append(candidate)
    }
    return parts.joined(separator: " · ")
  }
}
