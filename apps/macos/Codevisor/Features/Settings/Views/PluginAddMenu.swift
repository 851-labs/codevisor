import SwiftUI

struct PluginAddMenu: View {
  let canBrowse: Bool
  let onBrowse: () -> Void
  let onAddCustom: () -> Void

  var body: some View {
    SettingsAddMenu("Add Plugin") {
      if canBrowse {
        Button("Browse Plugins…", action: onBrowse)
      }
      Button("Add MCP…", action: onAddCustom)
    }
  }
}
