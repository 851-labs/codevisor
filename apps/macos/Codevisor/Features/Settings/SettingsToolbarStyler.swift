import AppKit
import SwiftUI

extension View {
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

  private final class StylerView: NSView {
    private static let sidebarMinimumWidth: CGFloat = 185
    private static let sidebarMaximumWidth: CGFloat = 240

    private var observation: NSObjectProtocol?

    isolated deinit {
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
      if let window {
        observation = NotificationCenter.default.addObserver(
          forName: NSWindow.didUpdateNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.apply() }
        }
      }
      apply()
    }

    func apply() {
      guard let window else { return }
      SettingsRouter.shared.controlWindow = window
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
