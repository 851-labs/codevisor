import AppKit
import CodevisorUI
import SwiftUI

struct SidebarVibrancyHost<Content: View>: NSViewRepresentable {
  @ViewBuilder var content: () -> Content

  func makeCoordinator() -> SidebarHostBridge { SidebarHostBridge() }

  func makeNSView(context: Context) -> SidebarHostingView<SidebarHostedContent<Content>> {
    context.coordinator.openSettings = context.environment.openSettings
    let host = SidebarHostingView(rootView: SidebarHostedContent(content: content(), bridge: context.coordinator))
    host.sizingOptions = []
    host.bridge = context.coordinator
    host.isHidden = !context.environment.isActiveSidebarMode
    return host
  }

  func updateNSView(_ host: SidebarHostingView<SidebarHostedContent<Content>>, context: Context) {
    let isActive = context.environment.isActiveSidebarMode
    host.isHidden = !isActive
    guard isActive else { return }
    context.coordinator.openSettings = context.environment.openSettings
    host.rootView = SidebarHostedContent(content: content(), bridge: context.coordinator)
  }
}

struct SidebarHostedContent<Content: View>: View {
  let content: Content
  let bridge: SidebarHostBridge

  var body: some View {
    content.environment(bridge)
  }
}

final class SidebarHostingView<Content: View>: NSHostingView<Content> {
  var bridge: SidebarHostBridge?

  override var isHidden: Bool {
    didSet {
      guard oldValue, !isHidden else { return }
      bridge?.recordReveal()
      needsLayout = true
    }
  }

  override func layout() {
    guard !isHidden else { return }
    super.layout()
  }
}
