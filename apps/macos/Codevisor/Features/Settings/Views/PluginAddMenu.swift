import SwiftUI

struct PluginAddMenu: View {
  let canBrowse: Bool
  let onBrowse: () -> Void
  let onAddCustom: () -> Void

  var body: some View {
    Menu {
      if canBrowse {
        Button("Browse Plugins…", action: onBrowse)
      }
      Button("Add Custom…", action: onAddCustom)
    } label: {
      Label("Add", systemImage: "plus")
    }
    .fixedSize()
  }
}
