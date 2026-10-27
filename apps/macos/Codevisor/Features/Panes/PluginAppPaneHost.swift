import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAppPaneHost: View {
  @Environment(AppEnvironment.self) private var environment
  let pane: PluginAppPane

  var body: some View {
    if let model = pane.model(environment: environment) {
      PluginAppPaneView(model: model)
    } else {
      ContentUnavailableView("App unavailable", systemImage: "puzzlepiece.extension")
    }
  }
}
