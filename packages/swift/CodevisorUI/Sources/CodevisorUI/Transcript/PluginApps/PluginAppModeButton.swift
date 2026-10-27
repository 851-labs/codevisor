import SwiftUI

struct PluginAppModeButton: View {
  let mode: PluginAppDisplayMode
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .help(title)
    .accessibilityLabel(title)
  }

  private var systemImage: String {
    switch mode {
    case .inline: "rectangle.inset.filled.and.person.filled"
    case .fullscreen: "arrow.up.left.and.arrow.down.right"
    case .pip: "pip.enter"
    }
  }

  private var title: String {
    switch mode {
    case .inline: "Show in Chat"
    case .fullscreen: "Open in Tab"
    case .pip: "Picture in Picture"
    }
  }
}
