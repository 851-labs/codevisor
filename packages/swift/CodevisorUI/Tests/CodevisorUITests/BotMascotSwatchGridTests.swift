import CoreGraphics
import Testing
@testable import CodevisorUI

@Suite("Bot mascot swatch grid")
struct BotMascotSwatchGridTests {
  private static let cell = CGSize(width: 30, height: 30)
  private static let spacing: CGFloat = 6

  @Test(
    "Splits swatches into the fewest rows that fit, then evens them out",
    arguments: [
      (count: 18, width: CGFloat(450), perRow: 9, rows: 2),
      (count: 18, width: CGFloat(300), perRow: 6, rows: 3),
      (count: 11, width: CGFloat(450), perRow: 11, rows: 1),
      (count: 11, width: CGFloat(260), perRow: 6, rows: 2),
    ])
  func balancesRows(count: Int, width: CGFloat, perRow: Int, rows: Int) {
    let grid = grid(count: count, width: width)

    #expect(grid.perRow == perRow)
    #expect(grid.rows == rows)
  }

  @Test("Keeps every swatch in one row when there's no width to fit")
  func unboundedWidthIsOneRow() {
    let grid = grid(count: 18, width: nil)

    #expect(grid.rows == 1)
    #expect(grid.size(filling: nil) == CGSize(width: 18 * 30 + 17 * 6, height: 30))
  }

  @Test("Centres each row, including a shorter last row")
  func centresRows() {
    let grid = grid(count: 11, width: 260)
    let bounds = CGRect(x: 0, y: 0, width: 260, height: 66)

    #expect(grid.origin(of: 0, in: bounds) == CGPoint(x: 25, y: 0))
    #expect(grid.origin(of: 6, in: bounds) == CGPoint(x: 43, y: 36))
    #expect(grid.items(inRow: 1) == 5)
  }

  private func grid(count: Int, width: CGFloat?) -> BotMascotSwatchGrid {
    BotMascotSwatchGrid(count: count, cell: Self.cell, spacing: Self.spacing, width: width)
  }
}
