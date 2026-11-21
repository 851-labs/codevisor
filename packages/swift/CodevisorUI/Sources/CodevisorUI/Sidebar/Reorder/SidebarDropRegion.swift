import CodevisorCore
import CoreGraphics
import Foundation

public struct SidebarDropRegion<RowID: Hashable>: Equatable {
  public let slots: [SidebarDropSlot<RowID>]
  public let movesSections: Bool
  public let firstInsertion: Int

  public init(slots: [SidebarDropSlot<RowID>], movesSections: Bool, firstInsertion: Int = 0) {
    self.slots = slots
    self.movesSections = movesSections
    self.firstInsertion = firstInsertion
  }

  public func slot(of id: UUID) -> SidebarDropSlot<RowID>? {
    slots.first { $0.itemID == id }
  }

  public func others(excluding id: UUID) -> [SidebarDropSlot<RowID>] {
    slots.filter { $0.itemID != id }
  }

  public func placement(insertingAt index: Int, excluding id: UUID) -> SidebarPlacement {
    let current = slot(of: id)?.section
    let others = others(excluding: id)
    guard others.indices.contains(index - 1) else {
      return SidebarPlacement(section: movesSections ? nil : current, after: nil)
    }

    let predecessor = others[index - 1]
    return SidebarPlacement(section: movesSections ? predecessor.section : current, after: predecessor.itemID)
  }

  public func placement(dropping id: UUID, below rowsAbove: [RowID]) -> SidebarPlacement? {
    let slotRows = Set(slots.map(\.row))
    let ownRow = slot(of: id)?.row
    let index = max(firstInsertion, rowsAbove.filter { slotRows.contains($0) && $0 != ownRow }.count)
    let dropped = placement(insertingAt: index, excluding: id)
    let current = slots.firstIndex { $0.itemID == id }.map { placement(insertingAt: $0, excluding: id) }
    return dropped == current ? nil : dropped
  }

  public func siblings(placing id: UUID, at placement: SidebarPlacement) -> [UUID] {
    let members = slots.filter { !movesSections || $0.section == placement.section }.compactMap(\.itemID)
    return placement.siblings(placing: id, among: members)
  }

  public func target(dragging id: UUID, ghost: CGRect, frames: [RowID: CGRect]) -> SidebarItemDropTarget? {
    guard let current = slots.firstIndex(where: { $0.itemID == id }) else { return nil }

    if let section = header(under: CGPoint(x: ghost.midX, y: ghost.midY), frames: frames, leaving: id) {
      return .header(section: section)
    }
    let index = max(firstInsertion, insertionIndex(dragging: id, midY: ghost.midY, frames: frames))
    return index == current ? nil : .insertion(index)
  }

  public func insertionLine(at index: Int, dragging id: UUID, frames: [RowID: CGRect]) -> CGRect? {
    SidebarDropLine.frame(at: index, among: others(excluding: id).compactMap { frame(of: $0, in: frames) })
  }

  public func measured(in frames: [RowID: CGRect]) -> Self {
    Self(slots: slots.filter { frames[$0.row] != nil }, movesSections: movesSections, firstInsertion: firstInsertion)
  }

  private func insertionIndex(dragging id: UUID, midY: CGFloat, frames: [RowID: CGRect]) -> Int {
    others(excluding: id).filter { frame(of: $0, in: frames).map { $0.midY < midY } ?? false }.count
  }

  private func header(under point: CGPoint, frames: [RowID: CGRect], leaving id: UUID) -> UUID?? {
    guard movesSections else { return nil }

    let current = slot(of: id)?.section
    let hit = slots.first { $0.isHeader && $0.section != current && frames[$0.row]?.contains(point) == true }
    return hit.map(\.section)
  }

  private func frame(of slot: SidebarDropSlot<RowID>, in frames: [RowID: CGRect]) -> CGRect? {
    SidebarDropLine.union(of: slot.rows, in: frames)
  }
}
