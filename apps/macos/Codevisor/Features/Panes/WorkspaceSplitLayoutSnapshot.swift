import CodevisorCore
import CoreGraphics
import Foundation

/// A local split insertion whose geometry is still being presented. The
/// workspace tree is already canonical; this value affects only the entering
/// shell and when its pane content becomes interactive.
struct WorkspaceSplitOpening: Equatable, Identifiable {
  let id = UUID()
  let leafId: UUID
  let edge: SplitEdge
}

/// The flat presentation of a split tree. Leaves remain siblings keyed by their
/// persistent group ids, so wrapping or collapsing a branch changes geometry
/// without changing the SwiftUI ownership path of surviving pane content.
struct WorkspaceSplitLayoutSnapshot {
  struct Leaf: Identifiable {
    let id: UUID
    let frame: CGRect
  }

  struct DividerID: Hashable {
    let branchPath: [Int]
    let childIndex: Int
  }

  struct Divider: Identifiable {
    let id: DividerID
    let branchPath: [Int]
    let childIndex: Int
    let isHorizontal: Bool
    let lineFrame: CGRect
    let gripFrame: CGRect
    let contentLength: CGFloat
    let sourceFractions: [Double]
    let beforeLeafID: UUID?
    let afterLeafID: UUID?
  }

  var leaves: [Leaf] = []
  var dividers: [Divider] = []

  static func make(
    node: SplitNode,
    size: CGSize
  ) -> WorkspaceSplitLayoutSnapshot {
    var result = WorkspaceSplitLayoutSnapshot()
    result.append(
      node,
      in: CGRect(origin: .zero, size: size),
      branchPath: []
    )
    return result
  }

  private mutating func append(
    _ node: SplitNode,
    in frame: CGRect,
    branchPath: [Int]
  ) {
    switch node {
    case let .group(id, _):
      leaves.append(Leaf(id: id, frame: frame))

    case let .split(orientation, children):
      guard !children.isEmpty else { return }
      let isHorizontal = orientation == .horizontal
      let axisLength = isHorizontal ? frame.width : frame.height
      let contentLength = max(axisLength - CGFloat(children.count - 1), 0)
      let minChildLength =
        isHorizontal
        ? WorkspaceSplitDragCoordinator.minChildWidth
        : WorkspaceSplitDragCoordinator.minChildHeight
      let sourceFractions = children.map(\.fraction)
      let fractions = SplitNode.flooredFractions(
        sourceFractions,
        minFraction: contentLength > 0
          ? Double(minChildLength / contentLength) : 0
      )

      var cursor = isHorizontal ? frame.minX : frame.minY
      for index in children.indices {
        let length = contentLength * CGFloat(fractions[index])
        let childFrame =
          if isHorizontal {
            CGRect(
              x: cursor,
              y: frame.minY,
              width: length,
              height: frame.height
            )
          } else {
            CGRect(
              x: frame.minX,
              y: cursor,
              width: frame.width,
              height: length
            )
          }
        append(
          children[index].node,
          in: childFrame,
          branchPath: branchPath + [index]
        )
        cursor += length

        guard index < children.count - 1 else { continue }
        let lineFrame =
          if isHorizontal {
            CGRect(x: cursor, y: frame.minY, width: 1, height: frame.height)
          } else {
            CGRect(x: frame.minX, y: cursor, width: frame.width, height: 1)
          }
        let gripFrame =
          if isHorizontal {
            CGRect(x: cursor - 6, y: frame.minY, width: 13, height: frame.height)
          } else {
            CGRect(x: frame.minX, y: cursor - 6, width: frame.width, height: 13)
          }
        dividers.append(
          Divider(
            id: DividerID(branchPath: branchPath, childIndex: index),
            branchPath: branchPath,
            childIndex: index,
            isHorizontal: isHorizontal,
            lineFrame: lineFrame,
            gripFrame: gripFrame,
            contentLength: contentLength,
            sourceFractions: sourceFractions,
            beforeLeafID: children[index].node.directLeafID,
            afterLeafID: children[index + 1].node.directLeafID
          ))
        cursor += 1
      }
    }
  }
}

private extension SplitNode {
  var directLeafID: UUID? {
    guard case let .group(id, _) = self else { return nil }
    return id
  }
}
