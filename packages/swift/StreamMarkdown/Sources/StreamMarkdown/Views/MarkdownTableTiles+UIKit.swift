#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  @MainActor
  final class MarkdownTableTiles {
    private struct Key: Hashable {
      let column: Int
      let row: Int
    }

    private static let spareLimit = 8
    private let painter = MarkdownTableCellPainter()
    private var tiles: [Key: MarkdownTableTileView] = [:]
    private var spares: [MarkdownTableTileView] = []

    func update(
      _ layout: UIKitMarkdownTableLayout, visible: CGRect, originY: CGFloat, in document: UIView,
      skipping skipped: Set<Int>
    ) {
      let bounds = CGRect(origin: .zero, size: layout.geometry.size)
      let wanted = Self.keys(covering: visible.intersection(bounds))
      for key in Array(tiles.keys) where !wanted.contains(key) {
        retire(key)
      }
      for key in wanted {
        let tableRect = Self.rect(of: key).intersection(bounds)
        let tile = tile(for: key, in: document)
        tile.frame = tableRect.offsetBy(dx: 0, dy: -originY)
        tile.show(layout, tableRect: tableRect, skipping: skipped)
      }
    }

    func removeAll() {
      for key in Array(tiles.keys) {
        retire(key)
      }
    }

    private func tile(for key: Key, in document: UIView) -> MarkdownTableTileView {
      if let tile = tiles[key] { return tile }

      let tile = spares.popLast() ?? MarkdownTableTileView(painter: painter)
      document.insertSubview(tile, at: 0)
      tiles[key] = tile
      return tile
    }

    private func retire(_ key: Key) {
      guard let tile = tiles.removeValue(forKey: key) else { return }

      tile.removeFromSuperview()
      if spares.count < Self.spareLimit { spares.append(tile) }
    }

    private static func keys(covering rect: CGRect) -> [Key] {
      guard !rect.isNull, !rect.isEmpty else { return [] }

      let size = MarkdownTableTileView.size
      let columns = Int(floor(rect.minX / size.width))...Int(floor((rect.maxX - 0.5) / size.width))
      let rows = Int(floor(rect.minY / size.height))...Int(floor((rect.maxY - 0.5) / size.height))
      return rows.flatMap { row in columns.map { Key(column: $0, row: row) } }
    }

    private static func rect(of key: Key) -> CGRect {
      let size = MarkdownTableTileView.size
      return CGRect(
        x: CGFloat(key.column) * size.width, y: CGFloat(key.row) * size.height,
        width: size.width, height: size.height)
    }
  }
#endif
