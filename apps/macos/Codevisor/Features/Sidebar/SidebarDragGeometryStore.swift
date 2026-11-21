import CodevisorUI
import Foundation

@MainActor
final class SidebarDragGeometryStore {
  var workspaces: [UUID: CGRect] = [:]
  var workspacePlacements: [UUID: SidebarRow.Placement] = [:]
  var tabs: [UUID: CGRect] = [:]
  var visibleRows: ClosedRange<CGFloat>?
}
