import AppKit
import CodevisorUI
import SwiftUI

struct SidebarVibrancyHost<Content: View>: NSViewRepresentable {
  @ViewBuilder var content: () -> Content

  func makeNSView(context: Context) -> SidebarHostingView<SidebarHostedContent<Content>> {
    let host = SidebarHostingView(rootView: SidebarHostedContent(content: content(), revealCount: 0))
    host.sizingOptions = []
    host.isHidden = !context.environment.isActiveSidebarMode
    return host
  }

  func updateNSView(_ host: SidebarHostingView<SidebarHostedContent<Content>>, context: Context) {
    let isActive = context.environment.isActiveSidebarMode
    host.isHidden = !isActive
    guard isActive else { return }
    host.rootView = SidebarHostedContent(content: content(), revealCount: host.revealCount)
  }
}

struct SidebarHostedContent<Content: View>: View {
  let content: Content
  let revealCount: Int

  var body: some View {
    content.environment(\.sidebarRevealCount, revealCount)
  }
}

final class SidebarHostingView<Content: View>: NSHostingView<Content> {
  private(set) var revealCount = 0

  override var isHidden: Bool {
    didSet {
      guard oldValue, !isHidden else { return }
      revealCount += 1
      needsLayout = true
    }
  }

  override func layout() {
    guard !isHidden else { return }
    super.layout()
  }
}
