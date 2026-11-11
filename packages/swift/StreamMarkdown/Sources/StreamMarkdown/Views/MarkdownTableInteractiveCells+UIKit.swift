#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  @MainActor
  final class MarkdownTableInteractiveCells {
    weak var delegate: UITextViewDelegate?
    private var views: [Int: SelectableTextKitView] = [:]
    private var spare: SelectableTextKitView?

    var ids: Set<Int> { Set(views.keys) }

    func view(for id: Int) -> SelectableTextKitView? {
      views[id]
    }

    func promote(_ id: Int, text: NSAttributedString, in document: UIView) -> SelectableTextKitView {
      if let view = views[id] { return view }

      demoteIdle()
      let view = spare ?? SelectableTextKitView()
      spare = nil
      view.delegate = delegate
      view.setContent(text)
      view.accessibilityLabel = MarkdownImageAttachment.plainText(text)
      document.addSubview(view)
      views[id] = view
      return view
    }

    func position(_ layout: UIKitMarkdownTableLayout, originY: CGFloat) {
      let geometry = layout.geometry
      let columnCount = geometry.columnOffsets.count - 1
      for (id, view) in views {
        let frame = MarkdownTableCellPainter.textFrame(
          geometry: geometry, row: id / columnCount, column: id % columnCount)
        view.frame = frame.offsetBy(dx: 0, dy: -originY)
        _ = view.contentHeight(forWidth: frame.width)
      }
    }

    func refresh(for layout: UIKitMarkdownTableLayout) {
      let columnCount = layout.geometry.columnOffsets.count - 1
      for (id, view) in views {
        let row = id / columnCount
        guard row < layout.cells.count else {
          demote(id)
          continue
        }
        view.setContent(layout.cells[row][id % columnCount])
      }
    }

    func retainVisible(_ visible: Set<Int>) {
      for id in ids where !visible.contains(id) && !isSelecting(id) {
        demote(id)
      }
    }

    func removeAll() {
      for id in ids {
        demote(id)
      }
    }

    private func demoteIdle() {
      for id in ids where !isSelecting(id) {
        demote(id)
      }
    }

    private func isSelecting(_ id: Int) -> Bool {
      guard let view = views[id] else { return false }

      return view.isFirstResponder && view.selectedRange.length > 0
    }

    private func demote(_ id: Int) {
      guard let view = views.removeValue(forKey: id) else { return }

      view.removeFromSuperview()
      view.selectedRange = NSRange(location: 0, length: 0)
      view.setContent(NSAttributedString())
      spare = view
    }
  }
#endif
