import AppKit
import SwiftUI

extension View {
  /// Forces the modern one-row toolbar — back button and title inline at
  /// the leading edge of the detail column (System Settings, Xcode 26) —
  /// on the window hosting this view. The same bridge also enforces the
  /// Settings sidebar's width on the underlying AppKit split item because
  /// this scene drops SwiftUI's maximum-width preference during dragging.
  ///
  /// Needed because the SwiftUI `Settings` scene hard-codes the legacy
  /// `.preference` toolbar style when it creates its window and ignores
  /// the `windowToolbarStyle` scene modifier. That legacy style stacks a
  /// centered window title above the toolbar items, which leaves a pushed
  /// page's back button floating alone on a second row.
  func settingsWindowToolbarStyle() -> some View {
    background(SettingsToolbarStyler())
  }
}

private struct SettingsToolbarStyler: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    StylerView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    (nsView as? StylerView)?.apply()
  }

  /// A zero-size probe whose only job is to restyle its window's toolbar.
  private final class StylerView: NSView {
    private static let sidebarMinimumWidth: CGFloat = 185
    private static let sidebarMaximumWidth: CGFloat = 240

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
      // Re-assert on window updates: the Settings scene re-derives its
      // toolbar as navigation pushes and pops swap the toolbar items.
      // The guard in apply() makes the common no-op case free.
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
      // .unified (not .unifiedCompact): the standard-height toolbar
      // System Settings and Xcode use, where AppKit renders toolbar
      // controls at large size, vertically centered.
      guard let window else { return }
      if window.toolbarStyle != .unified {
        window.toolbarStyle = .unified
      }
      applySidebarWidthLimits(in: window)
    }

    private func applySidebarWidthLimits(in window: NSWindow) {
      guard let contentView = window.contentView,
        let (controller, item) = settingsSplitView(in: contentView)
      else { return }

      if item.minimumThickness != Self.sidebarMinimumWidth {
        item.minimumThickness = Self.sidebarMinimumWidth
      }
      if item.maximumThickness != Self.sidebarMaximumWidth {
        item.maximumThickness = Self.sidebarMaximumWidth
      }
      if item.canCollapse {
        item.canCollapse = false
      }
      if item.canCollapseFromWindowResize {
        item.canCollapseFromWindowResize = false
      }
      if item.isCollapsed {
        item.isCollapsed = false
      }

      let currentWidth = item.viewController.view.frame.width
      guard currentWidth.isFinite, currentWidth > 0 else { return }
      let clampedWidth = min(
        max(currentWidth, Self.sidebarMinimumWidth),
        Self.sidebarMaximumWidth
      )
      guard abs(currentWidth - clampedWidth) > 0.5 else { return }
      controller.splitView.setPosition(clampedWidth, ofDividerAt: 0)
    }

    /// SwiftUI installs its NavigationSplitViewController beside the
    /// Settings window's hosting controller, so it is absent from the
    /// controller child tree. Its split view remains in the ordinary view
    /// hierarchy; find the vertical split whose leading item is a sidebar.
    private func settingsSplitView(
      in view: NSView
    ) -> (controller: NSSplitViewController, item: NSSplitViewItem)? {
      if let splitView = view as? NSSplitView,
        splitView.isVertical,
        let controller = splitView.delegate as? NSSplitViewController,
        let item = controller.splitViewItems.first,
        item.behavior == .sidebar
      {
        return (controller, item)
      }

      for subview in view.subviews {
        if let result = settingsSplitView(in: subview) {
          return result
        }
      }
      return nil
    }
  }
}
