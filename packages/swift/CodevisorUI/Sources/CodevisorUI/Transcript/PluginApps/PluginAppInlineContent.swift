import SwiftUI

struct PluginAppInlineContent: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let model: PluginAppInlineModel
  let restriction: String?

  var body: some View {
    if PluginAppSubjectPlaceholder.isBlocking(model.lookup.state, restriction: restriction) {
      PluginAppSubjectPlaceholder(state: model.lookup.state, restriction: restriction, onRetry: model.retry)
    } else {
      switch model.mode {
      case .inline:
        page
      case .pip:
        PluginAppInlinePlaceholder(
          systemImage: "pip", message: "Showing in picture in picture.", actionTitle: "Show Here",
          action: { model.request(.inline) })
      case .fullscreen where model.panePlacement == .split:
        PluginAppInlinePlaceholder(
          systemImage: "rectangle.split.2x1", message: "Open beside the chat.",
          actionTitle: "Show", action: model.revealFullscreen)
      case .fullscreen:
        PluginAppInlinePlaceholder(
          systemImage: "macwindow", message: "Open in its own tab.", actionTitle: "Show Tab",
          action: model.revealFullscreen)
      }
    }
  }

  @ViewBuilder
  private var page: some View {
    if model.page.phase == .closed {
      PluginAppInlinePlaceholder(
        systemImage: "xmark.circle", message: "App closed.", actionTitle: "Reopen", action: model.retry)
    } else {
      PluginAppPageView(page: model.page, onRetry: model.retry)
        .frame(maxWidth: .infinity)
        .frame(height: model.page.height)
        .pluginAppCard(filled: model.page.prefersBorder != false)
        .animation(reduceMotion ? nil : .snappy, value: model.page.height)
    }
  }
}
