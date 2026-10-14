import AppKit
import SwiftUI

struct SidebarVibrancyHost<Content: View>: NSViewRepresentable {
  @ViewBuilder var content: () -> Content

  func makeNSView(context: Context) -> NSHostingView<Content> {
    let host = NSHostingView(rootView: content())
    host.sizingOptions = []
    return host
  }

  func updateNSView(_ host: NSHostingView<Content>, context: Context) {
    host.rootView = content()
  }
}
