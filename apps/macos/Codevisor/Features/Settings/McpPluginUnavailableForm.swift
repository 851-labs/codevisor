import SwiftUI

struct McpPluginUnavailableForm: View {
  let isLoading: Bool

  var body: some View {
    Form {
      if isLoading {
        ProgressView().frame(maxWidth: .infinity)
      } else {
        ContentUnavailableView {
          Label("Plugin Unavailable", systemImage: "puzzlepiece.extension")
        } description: {
          Text("This plugin may have been removed.")
        } actions: {
          Button("Back to Plugins") { SettingsRouter.shared.panePath = [] }
        }
      }
    }
    .formStyle(.grouped)
  }
}
