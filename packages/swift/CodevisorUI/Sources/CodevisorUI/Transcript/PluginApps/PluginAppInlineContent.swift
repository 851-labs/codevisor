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
      case .fullscreen:
        PluginAppInlinePlaceholder(
          systemImage: "macwindow", message: "Open in its own tab.", actionTitle: "Show Tab",
          action: model.revealFullscreen)
      }
    }
  }

  private var page: some View {
    PluginAppPageView(page: model.page, onRetry: model.retry)
      .frame(maxWidth: .infinity)
      .frame(height: model.page.height)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
      .animation(reduceMotion ? nil : .snappy, value: model.page.height)
  }
}
