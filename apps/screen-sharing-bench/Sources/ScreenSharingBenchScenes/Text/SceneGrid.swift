struct SceneGrid {
  static let fontPoints = 13
  static let lineHeightPoints = 20

  let originX: Int
  let originY: Int
  let cellWidth: Int
  let cellHeight: Int
  let columns: Int
  let rows: Int

  func cellOrigin(column: Int, row: Int) -> (x: Int, y: Int) {
    (originX + column * cellWidth, originY + row * cellHeight)
  }
}
