import CodevisorUI
import SimulatorPane
import SwiftUI

enum WorkspaceSceneTitle {
  case fixed(String)
  case editable(Binding<String>)
}

struct WorkspaceSceneValues {
  var browser: ChromiumBrowserModel?
  var file: FilePaneModel?
  var simulator: SimulatorPaneModel?
  var layoutActions: WorkspaceLayoutActions?
}

struct WorkspaceSceneChrome<PaneToolbar: ToolbarContent>: View {
  let title: WorkspaceSceneTitle
  let removesTitle: Bool
  let values: WorkspaceSceneValues
  @ToolbarContentBuilder let toolbar: () -> PaneToolbar

  var body: some View {
    titled
      .toolbar(removing: removesTitle ? .title : nil)
      .toolbar(content: toolbar)
      .focusedSceneValue(\.browserPage, values.browser)
      .focusedSceneValue(\.filePane, values.file)
      .focusedSceneValue(\.simulatorPane, values.simulator)
      .focusedSceneValue(\.workspaceLayoutActions, values.layoutActions)
  }

  @ViewBuilder
  private var titled: some View {
    switch title {
    case let .fixed(text): Color.clear.navigationTitle(text)
    case let .editable(binding): Color.clear.navigationTitle(binding)
    }
  }
}
