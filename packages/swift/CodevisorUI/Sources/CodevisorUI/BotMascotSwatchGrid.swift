import CoreGraphics

struct BotMascotSwatchGrid: Equatable {
  let count: Int
  let cell: CGSize
  let spacing: CGFloat
  let perRow: Int

  init(count: Int, cell: CGSize, spacing: CGFloat, width: CGFloat?) {
    self.count = count
    self.cell = cell
    self.spacing = spacing
    let fitting = Self.fittingPerRow(cell: cell, spacing: spacing, width: width)
    perRow = Self.balancedPerRow(count: count, fitting: fitting)
  }

  var rows: Int {
    guard perRow > 0 else { return 0 }
    return (count + perRow - 1) / perRow
  }

  func size(filling width: CGFloat?) -> CGSize {
    CGSize(width: filledWidth(width), height: span(rows, of: cell.height))
  }

  func origin(of index: Int, in bounds: CGRect) -> CGPoint {
    let row = index / perRow
    let column = index % perRow
    let rowStart = bounds.midX - span(items(inRow: row), of: cell.width) / 2
    return CGPoint(
      x: rowStart + CGFloat(column) * (cell.width + spacing),
      y: bounds.minY + CGFloat(row) * (cell.height + spacing)
    )
  }

  func items(inRow row: Int) -> Int {
    min(perRow, count - row * perRow)
  }

  private func filledWidth(_ width: CGFloat?) -> CGFloat {
    let natural = span(perRow, of: cell.width)
    guard let width, width.isFinite else { return natural }
    return max(width, natural)
  }

  private func span(_ items: Int, of side: CGFloat) -> CGFloat {
    guard items > 0 else { return 0 }
    return CGFloat(items) * side + CGFloat(items - 1) * spacing
  }

  private static func fittingPerRow(cell: CGSize, spacing: CGFloat, width: CGFloat?) -> Int? {
    guard let width, width.isFinite, cell.width > 0 else { return nil }
    return max(1, Int(((width + spacing) / (cell.width + spacing)).rounded(.down)))
  }

  private static func balancedPerRow(count: Int, fitting: Int?) -> Int {
    guard count > 0 else { return 0 }
    guard let fitting, fitting < count else { return count }
    let rows = (count + fitting - 1) / fitting
    return (count + rows - 1) / rows
  }
}
