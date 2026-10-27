import SwiftUI

struct PluginAppPageView: View {
  let page: PluginAppPage
  let onRetry: () -> Void

  var body: some View {
    if case let .failed(message) = page.phase {
      PluginAppInlinePlaceholder(systemImage: "exclamationmark.triangle", message: message, action: onRetry)
    } else {
      ZStack {
        if let controller = page.webController {
          PluginAppWebView(controller: controller)
            .opacity(page.phase == .ready ? 1 : 0)
        }
        if page.phase != .ready {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
  }
}
