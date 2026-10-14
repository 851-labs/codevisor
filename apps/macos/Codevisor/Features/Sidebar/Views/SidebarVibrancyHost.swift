import AppKit
import SwiftUI

/// Renders sidebar content in its own `NSHostingView` inside the split
/// view's sidebar, so its text gets the sidebar glass's vibrancy as
/// Mail's and Finder's does.
///
/// SwiftUI draws `NavigationSplitView`'s sidebar column without that
/// vibrancy: `.primary` text comes out dark grey rather than black, and
/// `.tertiary` headings lighter than native ones. A hosting view nested in
/// the column renders the same views vibrantly (measured against Mail:
/// identical headings, black row text). Only hierarchical styles
/// (`.primary`, `.secondary`, `.tertiary`) become vibrant; explicit colors
/// draw as given.
///
/// The nested hosting view starts a separate SwiftUI graph, which inherits
/// no environment: callers pass in what the content reads.
struct SidebarVibrancyHost<Content: View>: NSViewRepresentable {
  @ViewBuilder var content: () -> Content

  func makeNSView(context: Context) -> NSHostingView<Content> {
    let host = NSHostingView(rootView: content())
    // The column sizes the sidebar; the content never sizes the column.
    host.sizingOptions = []
    return host
  }

  func updateNSView(_ host: NSHostingView<Content>, context: Context) {
    host.rootView = content()
  }
}
