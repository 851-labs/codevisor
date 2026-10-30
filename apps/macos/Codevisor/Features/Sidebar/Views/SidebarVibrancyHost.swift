import AppKit
import SwiftUI

struct SidebarVibrancyHost<Content: View>: NSViewRepresentable {
  @ViewBuilder var content: () -> Content

  func makeNSView(context: Context) -> SidebarHostingView<Content> {
    let host = SidebarHostingView(rootView: content())
    host.sizingOptions = []
    host.isHidden = !context.environment.isActiveSidebarMode
    return host
  }

  func updateNSView(_ host: SidebarHostingView<Content>, context: Context) {
    let isActive = context.environment.isActiveSidebarMode
    host.isHidden = !isActive
    guard isActive else { return }
    host.rootView = content()
  }
}

final class SidebarHostingView<Content: View>: NSHostingView<Content> {
  override var isHidden: Bool {
    didSet { if oldValue, !isHidden { needsLayout = true } }
  }

  override func layout() {
    guard !isHidden else { return }
    super.layout()
  }
}
