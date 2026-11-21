import CoreGraphics
import Foundation

public struct SidebarDropBlock<RowID: Hashable>: Equatable {
  public let header: RowID
  public let rows: [RowID]

  public init(header: RowID, rows: [RowID]) {
    self.header = header
    self.rows = rows
  }
}

public struct SidebarDropBlocks<RowID: Hashable>: Equatable {
  public let blocks: [SidebarDropBlock<RowID>]

  public init(_ blocks: [SidebarDropBlock<RowID>]) {
    self.blocks = blocks
  }

  public var headers: [RowID] { blocks.map(\.header) }

  public func target(dragging header: RowID, midY: CGFloat, frames: [RowID: CGRect]) -> Int? {
    guard let current = headers.firstIndex(of: header) else { return nil }

    let index = others(excluding: header).filter { frame(of: $0, in: frames).map { $0.midY < midY } ?? false }.count
    return index == current ? nil : index
  }

  public func insertionLine(at index: Int, dragging header: RowID, frames: [RowID: CGRect]) -> CGRect? {
    SidebarDropLine.frame(at: index, among: others(excluding: header).compactMap { frame(of: $0, in: frames) })
  }

  public func measured(in frames: [RowID: CGRect]) -> Self {
    Self(blocks.filter { frames[$0.header] != nil })
  }

  private func others(excluding header: RowID) -> [SidebarDropBlock<RowID>] {
    blocks.filter { $0.header != header }
  }

  private func frame(of block: SidebarDropBlock<RowID>, in frames: [RowID: CGRect]) -> CGRect? {
    SidebarDropLine.union(of: [block.header] + block.rows, in: frames)
  }
}
