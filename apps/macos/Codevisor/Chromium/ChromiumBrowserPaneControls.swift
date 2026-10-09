import CodevisorUI
import SwiftUI

/// A browser tab's controls in the row under the tab bar, in Liquid Glass
/// like Safari's: back and forward sharing one capsule, then the address
/// bar with its own glass.
struct ChromiumBrowserPaneControls: View {
  @Bindable var model: ChromiumBrowserModel

  var body: some View {
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        HStack(spacing: 0) {
          navigationButton("Back", symbol: "chevron.left", isEnabled: model.canGoBack) {
            model.webView?.goBack()
          }
          navigationButton("Forward", symbol: "chevron.right", isEnabled: model.canGoForward) {
            model.webView?.goForward()
          }
        }
        .padding(.horizontal, 2)
        .glassEffect(.regular.interactive(), in: .capsule)
        ChromiumBrowserToolbar(model: model).id(model.paneId).frame(maxWidth: .infinity)
      }
    }
  }

  private func navigationButton(
    _ title: String, symbol: String, isEnabled: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 30, height: 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(isEnabled ? .primary : .tertiary)
    .disabled(!isEnabled)
    .help(title)
    .accessibilityLabel(title)
  }
}
