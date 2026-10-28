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
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping @MainActor (CGFloat) -> Void) {
      self.onChange = onChange
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      attach()
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      attach()
    }

    private func attach() {
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      (column, splitView) = enclosingSplitColumn()
      guard let column, let splitView else { return }
      column.postsFrameChangedNotifications = true
      let sources: [(Notification.Name, NSView)] = [
        (NSView.frameDidChangeNotification, column), (NSSplitView.didResizeSubviewsNotification, splitView),
      ]
      observers = sources.map { name, object in
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.report() }
        }
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
