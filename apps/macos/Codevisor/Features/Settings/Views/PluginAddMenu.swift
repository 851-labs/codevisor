import SwiftUI

struct PluginAddMenu: View {
  let onBrowse: () -> Void
  let onAddCustom: () -> Void

  var body: some View {
    SettingsAddMenu("Add Plugin") {
      Button("Browse Plugins…", action: onBrowse)
      Button("Add MCP…", action: onAddCustom)
    }
  }
}
