import SwiftUI

struct HomeSidebarCollectionRow {
  nonisolated enum ID: Hashable, Sendable {
    case outline(HomeSidebarOutline.RowID)
    case nested(UUID)
    case notice
    case archivedHeader
    case archived(UUID)
    case showMore
  }

  nonisolated enum Section: Hashable, Sendable {
    case outline
    case archived
  }

  enum Background {
    case system
    case clear
    case card(HomeSidebarCardEdges)
  }

  enum Drag {
    case item
    case section(UUID)
  }

  let id: ID
  var section = Section.outline
  var outlineIndex: Int?
  var drag: Drag?
  var member: UUID?
  var startsBlock = false
  var margins: EdgeInsets?
  var background = Background.system
  var hiddenSeparators: VerticalEdge.Set = []
  var selectionID: UUID?
  var previewTopInset: CGFloat?
  var menu: HomeSidebarMenu?
  var content: AnyView

  var draggedSection: UUID? {
    guard case let .section(id) = drag else { return nil }
    return id
  }
}
