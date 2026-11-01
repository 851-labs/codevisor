import CodevisorCore
import Foundation

struct HomeSidebarSectionActions {
  var move: (_ memberID: UUID, _ sectionID: UUID?) -> Void = { _, _ in }
  var create: (_ moving: UUID?) -> Void = { _ in }
  var rename: (CustomSection) -> Void = { _ in }
  var delete: (CustomSection) -> Void = { _ in }
  var reorder: (_ sectionID: UUID, _ index: Int) -> Void = { _, _ in }
}
