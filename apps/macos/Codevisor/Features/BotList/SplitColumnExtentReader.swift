import AppKit
import SwiftUI

struct SplitColumnExtentReader: NSViewRepresentable {
  let onChange: @MainActor (CGFloat) -> Void

  func makeNSView(context: Context) -> Probe { Probe(onChange: onChange) }
  func updateNSView(_ nsView: Probe, context: Context) { nsView.onChange = onChange }

  final class Probe: NSView {
    var onChange: @MainActor (CGFloat) -> Void
    private weak var column: NSView?
    private weak var splitView: NSSplitView?
    private var observer: NSObjectProtocol?

    init(onChange: @escaping @MainActor (CGFloat) -> Void) {
      self.onChange = onChange
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      (column, splitView) = enclosingSplitColumn()
      guard let column else { return }
      column.postsFrameChangedNotifications = true
      observer = NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: column, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.report() }
      }
      report()
    }

    private func enclosingSplitColumn() -> (NSView?, NSSplitView?) {
      var view: NSView = self
      while let parent = view.superview {
        if let splitView = parent as? NSSplitView { return (view, splitView) }
        view = parent
      }
      return (nil, nil)
    }

    private func report() {
      guard let column, let splitView else { return }
      let isCollapsed = column.isHidden || splitView.isSubviewCollapsed(column)
      onChange(isCollapsed ? 0 : max(0, column.frame.maxX))
    }
  }
}
