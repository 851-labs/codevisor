import CodevisorCore
import SwiftUI

struct PluginAppPipWindow: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let model: PluginAppInlineModel
  let container: CGSize
  @State private var corner: PluginAppPipLayout.Corner = .topTrailing
  @State private var dragOffset: CGSize = .zero

  var body: some View {
    let size = PluginAppPipLayout.size(
      contentHeight: model.page.height, container: container, preferredWidth: Self.preferredWidth)
    let origin = PluginAppPipLayout.origin(corner: corner, size: size, container: container)
    VStack(spacing: 0) {
      PluginAppPipHeader(model: model, isRestricted: restriction != nil)
        .gesture(drag(size: size, origin: origin))
      content
    }
    .frame(width: size.width, height: size.height)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    .shadow(radius: 12, y: 4)
    .offset(x: origin.x + dragOffset.width, y: origin.y + dragOffset.height)
    .animation(reduceMotion ? nil : .snappy, value: corner)
    .onChange(of: colorScheme, initial: true) { _, _ in showPage() }
    .transition(.opacity)
  }

  private static var preferredWidth: CGFloat {
    #if os(iOS)
      300
    #else
      360
    #endif
  }

  private var restriction: String? {
    model.subject.flatMap(environment.pluginAccess.restriction(for:))
  }

  @ViewBuilder
  private var content: some View {
    if let restriction {
      PluginAppInlinePlaceholder(systemImage: "hand.raised", message: restriction)
        .padding(8)
    } else {
      PluginAppPageView(page: model.page, onRetry: model.retry)
    }
  }

  private func showPage() {
    guard restriction == nil else { return }

    model.show(
      display: PluginAppDisplay(
        isDark: colorScheme == .dark, platform: PluginAppDisplay.currentPlatform,
        locale: PluginAppDisplay.currentLocale))
  }

  private func drag(size: CGSize, origin: CGPoint) -> some Gesture {
    DragGesture()
      .onChanged { value in dragOffset = value.translation }
      .onEnded { value in
        let center = CGPoint(
          x: origin.x + value.translation.width + size.width / 2,
          y: origin.y + value.translation.height + size.height / 2)
        corner = PluginAppPipLayout.nearestCorner(to: center, container: container)
        dragOffset = .zero
      }
  }
}
