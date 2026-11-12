import CodevisorUI
import Foundation
import Observation

@Observable
final class BotRowReorder {
  static let space = "botSidebar.reorder"

  private(set) var drag: BotRowDrag?
  @ObservationIgnored var frames: [BotSidebarRowID: CGRect] = [:]

  func isDragging(_ botID: UUID) -> Bool {
    drag?.botID == botID
  }

  func lift(_ botID: UUID) {
    guard let frame = frames[.bot(botID)], frame != .zero else { return }
    drag = BotRowDrag(botID: botID, liftedFrame: frame)
  }

  func move(_ botID: UUID, by translation: CGFloat, in rows: [BotSidebarRow]) {
    guard drag?.botID == botID else { return }

    drag?.translation = translation
    let target = drag.flatMap { target(for: $0, in: rows) }
    if target != drag?.target { drag?.target = target }
  }

  func drop() -> BotRowDrag? {
    defer { drag = nil }
    return drag
  }

  func insertionLine(in rows: [BotSidebarRow]) -> CGRect? {
    guard let drag, case let .insertion(index) = drag.target else { return nil }

    let others = BotSidebarRows.dropSlots(in: rows).filter { $0 != .bot(drag.botID) }.compactMap { frames[$0] }
    return SidebarInsertionLine.frame(at: index, among: others)
  }

  private func target(for drag: BotRowDrag, in rows: [BotSidebarRow]) -> BotRowDrag.Target? {
    if let section = header(under: drag.ghostCenter, in: rows), section != self.section(of: drag.botID, in: rows) {
      return .section(section)
    }
    let slots = BotSidebarRows.dropSlots(in: rows)
    guard
      let index = ListReorder.destinationIndex(
        of: .bot(drag.botID), in: slots, frames: frames, midY: drag.ghostFrame.midY),
      index != slots.firstIndex(of: .bot(drag.botID))
    else { return nil }
    return .insertion(index)
  }

  private func header(under point: CGPoint, in rows: [BotSidebarRow]) -> UUID? {
    for row in rows {
      guard case let .section(section, _) = row.kind, frames[row.id]?.contains(point) == true else { continue }
      return section.id
    }
    return nil
  }

  private func section(of botID: UUID, in rows: [BotSidebarRow]) -> UUID? {
    for row in rows {
      guard case let .bot(conversation, section) = row.kind, conversation.id == botID else { continue }
      return section
    }
    return nil
  }
}
