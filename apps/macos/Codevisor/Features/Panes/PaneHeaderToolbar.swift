import CodevisorUI
import SimulatorPane
import SwiftUI

struct PaneHeaderToolbar: View {
  enum Slot {
    case leading, principal, trailing
  }

  let source: PaneToolbarSource
  let slot: Slot
  let onNewTab: () -> Void

  private static let addressMinimumWidth: CGFloat = 140

  var body: some View {
    Group {
      switch slot {
      case .leading: leading
      case .principal: principal
      case .trailing: trailing
      }
    }
    .labelStyle(.iconOnly)
  }

  @ViewBuilder
  private var leading: some View {
    switch source {
    case let .browser(model): ChromiumBrowserNavigationButtons(model: model)
    case let .screenSharing(pane): pane.store.map(ScreenSharingLeadingControls.init)
    case let .simulator(model): SimulatorPaneDeviceControl(model: model)
    case .file, .review: EmptyView()
    }
  }

  @ViewBuilder
  private var principal: some View {
    if case let .browser(model) = source {
      ChromiumBrowserToolbar(model: model, minimumWidth: Self.addressMinimumWidth)
    }
  }

  @ViewBuilder
  private var trailing: some View {
    switch source {
    case let .screenSharing(pane):
      if let store = pane.store {
        ScreenSharingTrailingControls(
          store: store, settings: { pane.machineSettings() }, applySettings: { pane.applyMachineSettings($0) })
      }
    case let .file(model): FilePaneToolbarActions(model: model, onNewTab: onNewTab)
    case let .review(model): ReviewPaneToolbarActions(model: model)
    case let .simulator(model): SimulatorPaneActions(model: model)
    case .browser: EmptyView()
    }
  }
}
