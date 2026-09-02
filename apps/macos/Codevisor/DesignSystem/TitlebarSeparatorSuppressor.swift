import AppKit
import SwiftUI

extension View {
  /// Removes the hairline AppKit draws between the title bar and this
  /// `NavigationSplitView` column.
  ///
  /// Scoped deliberately. The obvious lever, `NSWindow.titlebarSeparatorStyle`,
  /// does NOT work here: SwiftUI backs each column with its own
  /// `NSSplitViewItem`, and an item's `titlebarSeparatorStyle` overrides the
  /// window-level one, so the window setting is silently ignored. This walks
  /// to the owning item instead, which also keeps the change off the sidebar
  /// column — a window-wide fix would flatten the sidebar's seamless title
  /// bar too.
  func hidesTitlebarSeparator() -> some View {
    background(TitlebarSeparatorSuppressor())
  }
}

private struct TitlebarSeparatorSuppressor: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    SuppressorView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    (nsView as? SuppressorView)?.apply()
  }

  /// A zero-size probe whose only job is to locate its split-view item.
  private final class SuppressorView: NSView {
    private var observation: NSObjectProtocol?

    deinit {
      if let observation {
        NotificationCenter.default.removeObserver(observation)
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()

      if let observation {
        NotificationCenter.default.removeObserver(observation)
        self.observation = nil
      }
      // Re-assert on window updates: AppKit re-derives the automatic
      // style when the view adjacent to the title bar changes, and the
      // pane tab bar is a horizontal ScrollView — opening a second tab
      // is exactly what puts a scroll view under the title bar. The
      // guard in apply() makes the common no-op case free.
      if let window {
        observation = NotificationCenter.default.addObserver(
          forName: NSWindow.didUpdateNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          self?.apply()
        }
      }
      apply()
    }

    func apply() {
      guard let item = enclosingSplitViewItem(),
        item.titlebarSeparatorStyle != .none
      else { return }
      item.titlebarSeparatorStyle = .none
    }

    /// The split-view item whose column contains this view, if any.
    private func enclosingSplitViewItem() -> NSSplitViewItem? {
      guard let root = window?.contentViewController else { return nil }

      var pending = [root]
      while let controller = pending.popLast() {
        if let split = controller as? NSSplitViewController {
          for item in split.splitViewItems
          where isDescendant(of: item.viewController.view) {
            return item
          }
        }
        pending.append(contentsOf: controller.children)
      }
      return nil
    }
  }
}
