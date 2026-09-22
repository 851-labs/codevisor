import CodevisorCore
import CoreGraphics
import Foundation

/// The flat presentation of a split tree. Leaves remain siblings keyed by their
/// persistent group ids, so wrapping or collapsing a branch changes geometry
/// without changing the SwiftUI ownership path of surviving pane content.
/// Shared by the macOS split view and the iPhone Duo split container.
public struct WorkspaceSplitLayoutSnapshot: Equatable {
  public struct Leaf: Identifiable, Equatable {
    public let id: UUID
    public let frame: CGRect
  }

  public struct DividerID: Hashable {
    public let branchPath: [Int]
    public let childIndex: Int
  }

  public struct Divider: Identifiable, Equatable {
    public let id: DividerID
    public let branchPath: [Int]
    public let childIndex: Int
    public let isHorizontal: Bool
    public let lineFrame: CGRect
    public let gripFrame: CGRect
    public let contentLength: CGFloat
    public let sourceFractions: [Double]
    public let beforeLeafID: UUID?
    public let afterLeafID: UUID?
  }

  /// The smallest a child may render along the split axis; below this the
  /// fractions are floored so every pane stays usable.
  public static let defaultMinChildWidth: CGFloat = 320
  public static let defaultMinChildHeight: CGFloat = 280

  public var leaves: [Leaf] = []
  public var dividers: [Divider] = []

  public static func make(
    node: SplitNode,
    size: CGSize,
    minChildWidth: CGFloat = defaultMinChildWidth,
    minChildHeight: CGFloat = defaultMinChildHeight
  ) -> WorkspaceSplitLayoutSnapshot {
    var result = WorkspaceSplitLayoutSnapshot()
    result.append(
      node,
      in: CGRect(origin: .zero, size: size),
      branchPath: [],
      minChildWidth: minChildWidth,
      minChildHeight: minChildHeight
    )
    return result
  }

  private mutating func append(
    _ node: SplitNode,
    in frame: CGRect,
    branchPath: [Int],
    minChildWidth: CGFloat,
    minChildHeight: CGFloat
  ) {
    switch node {
    case let .group(id, _):
      leaves.append(Leaf(id: id, frame: frame))

    case let .split(orientation, children):
      guard !children.isEmpty else { return }
      let isHorizontal = orientation == .horizontal
      let axisLength = isHorizontal ? frame.width : frame.height
      let contentLength = max(axisLength - CGFloat(children.count - 1), 0)
      let minChildLength = isHorizontal ? minChildWidth : minChildHeight
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
            CGRect(x: cursor, y: frame.minY, width: length, height: frame.height)
          } else {
            CGRect(x: frame.minX, y: cursor, width: frame.width, height: length)
          }
        append(
          children[index].node,
          in: childFrame,
          branchPath: branchPath + [index],
          minChildWidth: minChildWidth,
          minChildHeight: minChildHeight
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

extension SplitNode {
  /// The group id when this node is itself a leaf.
  public var directLeafID: UUID? {
    guard case let .group(id, _) = self else { return nil }
    return id
  }
}
