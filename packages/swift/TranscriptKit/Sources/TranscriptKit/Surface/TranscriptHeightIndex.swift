import CoreGraphics

/// Immutable height index. Small leaves amortize allocation, while path copying
/// preserves old geometry for anchor compensation without copying the document.
/// A point update or coordinate lookup visits O(log rows) nodes; a full batch
/// visits each affected subtree once.
struct TranscriptHeightIndex: Sendable, Equatable {
  struct Row: Sendable, Equatable {
    let height: CGFloat
    let spacing: CGFloat
    var extent: CGFloat { height + spacing }
  }

  struct Geometry {
    let top: CGFloat
    let height: CGFloat
  }

  private final class Node: Sendable {
    let count: Int
    let extent: CGFloat
    let left: Node?
    let right: Node?
    let rows: [Row]

    init(rows: [Row]) {
      self.rows = rows
      count = rows.count
      extent = rows.reduce(0) { $0 + $1.extent }
      left = nil
      right = nil
    }

    init(left: Node, right: Node) {
      self.left = left
      self.right = right
      rows = []
      count = left.count + right.count
      extent = left.extent + right.extent
    }

    static func build(_ rows: ArraySlice<Row>) -> Node {
      guard rows.count > 32 else { return Node(rows: Array(rows)) }
      let middle = rows.startIndex + rows.count / 2
      return Node(left: build(rows[..<middle]), right: build(rows[middle...]))
    }

    func geometry(at index: Int, top: CGFloat = 0) -> Geometry {
      if let left, let right {
        return index < left.count
          ? left.geometry(at: index, top: top)
          : right.geometry(at: index - left.count, top: top + left.extent)
      }
      var offset = top
      for row in rows.prefix(index) { offset += row.extent }
      return Geometry(top: offset, height: rows[index].height)
    }

    /// Both searches return count when the requested edge is past this subtree.
    func firstIndex(at offset: CGFloat, searchingBottom: Bool) -> Int {
      if let left, let right {
        if offset < left.extent {
          return left.firstIndex(at: offset, searchingBottom: searchingBottom)
        }
        return left.count
          + right.firstIndex(
            at: offset - left.extent, searchingBottom: searchingBottom
          )
      }
      var top: CGFloat = 0
      for (index, row) in rows.enumerated() {
        if searchingBottom ? top + row.height > offset : top >= offset { return index }
        top += row.extent
      }
      return count
    }

    func replacing(
      _ updates: ArraySlice<(index: Int, height: CGFloat)>,
      start: Int,
      visited: inout Int
    ) -> Node {
      guard !updates.isEmpty else { return self }
      visited += 1
      if let left, let right {
        let boundary = start + left.count
        var low = updates.startIndex
        var high = updates.endIndex
        while low < high {
          let middle = (low + high) / 2
          if updates[middle].index < boundary { low = middle + 1 } else { high = middle }
        }
        let nextLeft = left.replacing(updates[..<low], start: start, visited: &visited)
        let nextRight = right.replacing(updates[low...], start: boundary, visited: &visited)
        if nextLeft === left, nextRight === right { return self }
        return Node(left: nextLeft, right: nextRight)
      }
      var nextRows = rows
      var changed = false
      for update in updates {
        let index = update.index - start
        if rows[index].height != update.height {
          nextRows[index] = Row(height: update.height, spacing: rows[index].spacing)
          changed = true
        }
      }
      return changed ? Node(rows: nextRows) : self
    }

    func appendRows(to result: inout [Row]) {
      if let left, let right {
        left.appendRows(to: &result)
        right.appendRows(to: &result)
      } else {
        result.append(contentsOf: rows)
      }
    }
  }

  private let root: Node
  /// Counts actual tree visits, allowing complexity assertions without a clock.
  let updatedNodeCount: Int
  var count: Int { root.count }
  var totalHeight: CGFloat { root.extent }

  init(rows: [Row]) {
    root = Node.build(rows[...])
    updatedNodeCount = 0
  }

  private init(root: Node, updatedNodeCount: Int) {
    self.root = root
    self.updatedNodeCount = updatedNodeCount
  }

  func geometry(at index: Int) -> Geometry { root.geometry(at: index) }

  func firstBottomExceeding(_ offset: CGFloat) -> Int {
    min(max(0, count - 1), root.firstIndex(at: offset, searchingBottom: true))
  }

  func firstTopReaching(_ offset: CGFloat) -> Int {
    root.firstIndex(at: offset, searchingBottom: false)
  }

  func replacing(_ updates: [(index: Int, height: CGFloat)]) -> Self {
    let sorted = updates.sorted { $0.index < $1.index }
    var visited = 0
    let next = root.replacing(sorted[...], start: 0, visited: &visited)
    return Self(root: next, updatedNodeCount: visited)
  }

  func allRows() -> [Row] {
    var result: [Row] = []
    result.reserveCapacity(count)
    root.appendRows(to: &result)
    return result
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.root === rhs.root || lhs.allRows() == rhs.allRows()
  }
}
