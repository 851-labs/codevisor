import Foundation

public enum SidebarItemDropTarget: Equatable, Sendable {
  case header(section: UUID?)
  case insertion(Int)
}
