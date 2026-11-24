import CodevisorUI
import SimulatorPane
import SwiftUI

struct WorkspacePaneToolbar: ToolbarContent {
  let source: PaneToolbarSource?
  let title: String

  var body: some ToolbarContent {
    if let browser = source?.browser {
      ChromiumBrowserNavigationControls(model: browser)
      ChromiumBrowserAddressToolbarItem(model: browser)
    } else {
      machineToolbar
    }
  }

  @ToolbarContentBuilder
  private var machineToolbar: some ToolbarContent {
    if let pane = source?.screenSharing, let store = pane.store {
      ScreenSharingToolbar(
        store: store, settings: { pane.machineSettings() }, applySettings: { pane.applyMachineSettings($0) })
    } else {
      documentToolbar
    }
  }

  @ToolbarContentBuilder
  private var documentToolbar: some ToolbarContent {
    if let file = source?.file {
      FilePaneToolbar(model: file, transfers: MacFileTransfers.transfers)
    } else {
      reviewOrSimulatorToolbar
    }
  }

  @ToolbarContentBuilder
  private var reviewOrSimulatorToolbar: some ToolbarContent {
    if let review = source?.review {
      ReviewPaneToolbar(model: review, title: title)
    } else if let simulator = source?.simulator {
      SimulatorPaneToolbar(model: simulator) { data, name in
        AppleSimulatorPane.saveScreenshot(data, deviceName: name)
      }
    }
  }
}
