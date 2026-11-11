#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  @MainActor
  final class MarkdownTableDocumentView: UIView {
    var interactiveCell: ((CGPoint) -> UIView?)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      if let hit = super.hitTest(point, with: event), hit !== self { return hit }
      guard event?.type == .touches, self.point(inside: point, with: event), let cell = interactiveCell?(point) else {
        return super.hitTest(point, with: event)
      }

      return cell.hitTest(convert(point, to: cell), with: event) ?? self
    }
  }
#endif
