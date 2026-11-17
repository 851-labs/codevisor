import CodevisorUI

final class SidebarShownRows {
  private(set) var rows: [SidebarRow] = []
  private(set) var ids: Set<SidebarRowID> = []

  func show(_ rows: [SidebarRow]) -> Set<SidebarRowID> {
    self.rows = rows
    ids = Set(rows.map(\.id))
    return ids
  }
}
