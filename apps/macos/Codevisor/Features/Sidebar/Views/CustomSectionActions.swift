import CodevisorCore
import Foundation

struct CustomSectionActions {
  let canMoveUp: Bool
  let canMoveDown: Bool
  let rename: () -> Void
  let delete: () -> Void
  let moveUp: () -> Void
  let moveDown: () -> Void

  init(
    sections: [CustomSection], section: CustomSection, rename: @escaping (CustomSection) -> Void,
    delete: @escaping (CustomSection) -> Void, move: @escaping (_ sectionID: UUID, _ index: Int) -> Void
  ) {
    let index = sections.firstIndex { $0.id == section.id } ?? 0
    canMoveUp = index > 0
    canMoveDown = index < sections.count - 1
    self.rename = { rename(section) }
    self.delete = { delete(section) }
    moveUp = { move(section.id, index - 1) }
    moveDown = { move(section.id, index + 1) }
  }
}
