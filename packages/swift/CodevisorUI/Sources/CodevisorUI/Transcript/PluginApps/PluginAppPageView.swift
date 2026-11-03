import SwiftUI

public struct PluginAppPageView: View {
  let page: PluginAppPage
  let onRetry: () -> Void

  public init(page: PluginAppPage, onRetry: @escaping () -> Void) {
    self.page = page
    self.onRetry = onRetry
  }

  public var body: some View {
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
