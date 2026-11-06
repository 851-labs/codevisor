import AppKit

enum SidebarSplitController {
  static func find(in view: NSView) -> NSSplitViewController? {
    if let controller = sidebarController(of: view) { return controller }
    return view.subviews.lazy.compactMap(find(in:)).first
  }

  private static func sidebarController(of view: NSView) -> NSSplitViewController? {
    guard let splitView = view as? NSSplitView, splitView.isVertical,
      let controller = splitView.delegate as? NSSplitViewController,
      controller.splitViewItems.first?.behavior == .sidebar
    else { return nil }
    return controller
  }
}
