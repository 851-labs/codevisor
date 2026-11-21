import CodevisorUI
import CoreGraphics

struct HomeSidebarSectionDrag {
  typealias Row = HomeSidebarCollectionRow

  let header: Row.ID
  let order: [Row.ID]
  let row: (Row.ID) -> Row?

  func order(at midY: CGFloat, frames: [Row.ID: CGRect]) -> [Row.ID]? {
    guard let target = blocks.target(dragging: header, midY: midY, frames: frames) else { return nil }
    return placing(at: target)
  }

  private var blocks: SidebarDropBlocks<Row.ID> {
    SidebarDropBlocks(
      order.compactMap { id in
        row(id)?.draggedSection.map { section in
          SidebarDropBlock(header: id, rows: order.filter { row($0)?.member == section })
        }
      })
  }

  private func placing(at target: Int) -> [Row.ID] {
    var others = order.filter { $0 != header }
    let headers = blocks.headers.filter { $0 != header }
    let anchor = headers.indices.contains(target) ? headers[target] : trailingAnchor(in: others)
    let index = anchor.flatMap { others.firstIndex(of: $0) } ?? others.count
    others.insert(header, at: index)
    return others
  }

  private func trailingAnchor(in others: [Row.ID]) -> Row.ID? {
    others.first { id in
      guard let row = row(id) else { return false }
      return row.startsBlock && row.draggedSection == nil
    }
  }
}
