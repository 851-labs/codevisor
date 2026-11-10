#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  @MainActor
  final class MarkdownTableTileView: UIView {
    static let size = CGSize(width: 512, height: 384)

    private(set) var tableRect: CGRect = .zero
    private weak var layout: UIKitMarkdownTableLayout?
    private var skipped: Set<Int> = []
    private let painter: MarkdownTableCellPainter

    init(painter: MarkdownTableCellPainter) {
      self.painter = painter
      super.init(frame: .zero)
      isOpaque = false
      backgroundColor = .clear
      isUserInteractionEnabled = false
      contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ layout: UIKitMarkdownTableLayout, tableRect: CGRect, skipping skipped: Set<Int>) {
      guard self.layout !== layout || self.tableRect != tableRect || self.skipped != skipped else { return }

      self.layout = layout
      self.tableRect = tableRect
      self.skipped = skipped
      setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
      guard let layout, let context = UIGraphicsGetCurrentContext() else { return }

      context.translateBy(x: -tableRect.minX, y: -tableRect.minY)
      let dirty = rect.offsetBy(dx: tableRect.minX, dy: tableRect.minY)
      painter.draw(layout, in: dirty, skipping: skipped)
    }
  }
#endif
